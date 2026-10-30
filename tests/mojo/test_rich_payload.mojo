from akasha.document.codec import decode_payload, encode_payload
from akasha.document.json_path import JsonPath
from akasha.document.payload_path import payload_value_get, payload_value_set, payload_value_remove
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.storage.checksum import BinaryWriter
from akasha.storage.filesystem import read_file_bytes
from akasha.index.metadata import MetadataIndex
from akasha.query.evaluator import matches_all
from akasha.query.filter_ast import FilterCondition
from bindings.payload_python import json_value_from_python, payload_value_to_python
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite


def _json(text: String) raises -> PayloadValue:
    return json_value_from_python(Python.import_module("json").loads(text))


def test_rich_paths_match_original_qdrant_and_round_trip_codec() raises:
    var fixture = Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-payload-values/values.json").read())
    var cases = fixture["cases"]
    for i in range(len(cases)):
        var row = cases[i]
        var root = json_value_from_python(row["input"])
        var path = Optional[JsonPath]()
        if not (row["path"] is Python.none()):
            path = Optional(JsonPath.parse(String(py=row["path"])))
        var values = List[PayloadValue]()
        var op = String(py=row["op"])
        if op == "get":
            values = payload_value_get(root, path.value())
        elif op == "set":
            var source = json_value_from_python(row["source"])
            payload_value_set(root, path, source)
        else:
            values = payload_value_remove(root, path.value())
        var expected = json_value_from_python(row["output"])
        assert_true(root.same_representation(expected), "root at case " + String(i))
        var actual = PayloadValue.array(values^)
        var expected_values = json_value_from_python(row["values"])
        assert_true(actual.same_representation(expected_values), "values at case " + String(i))
        var fields = List[DocumentField]()
        fields.append(DocumentField("root", root.clone()))
        var encoded = encode_payload(fields)
        var decoded = decode_payload(encoded^)
        assert_true(decoded[0].value.same_representation(root))
        # JSON boundary preserves nested order/type/negative zero, not just ==.
        var converted = json_value_from_python(payload_value_to_python(root))
        assert_true(converted.same_representation(root))


def test_container_ownership_duplicate_keys_null_and_unsigned() raises:
    var keys: List[String] = ["a", "b", "a", "", "nul\0key"]
    var children = List[PayloadValue]()
    children.append(PayloadValue.integer(1))
    children.append(PayloadValue.null())
    children.append(PayloadValue.integer(3))
    children.append(PayloadValue.unsigned(UInt64.MAX))
    children.append(PayloadValue.array(List[PayloadValue]()))
    var root = PayloadValue.object(keys^, children^)
    assert_equal(root.get_key("a").value().as_int(), Int64(3))
    assert_equal(root.keys()[1], "b")
    assert_true(root.get_key("b").value().is_null())
    assert_false(Bool(root.get_key("missing")))
    assert_equal(root.get_key("").value().as_uint(), UInt64.MAX)
    var clone = root.clone()
    var removed = payload_value_remove(clone, JsonPath.parse("a"))
    assert_equal(clone.keys()[0], "nul\0key")
    assert_equal(root.keys()[0], "a")
    assert_equal(removed[0].as_int(), Int64(3))


def test_rich_direct_and_indexed_matches_use_qdrant_value_checker() raises:
    var fixture = Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-payload-values/values.json").read())["filters"]
    for i in range(len(fixture)):
        var row = fixture[i]
        var mode = String(py=row["kind"])
        var literal: PayloadValue
        if mode == "eq_int" or mode == "ne_int":
            literal = PayloadValue.integer(2)
        elif mode == "eq_bool":
            literal = PayloadValue.boolean(True)
        else:
            literal = PayloadValue.string("2")
        var op = FilterCondition.NOT_EQUAL if mode == "ne_int" or mode == "ne_string" else FilterCondition.EQUAL
        var condition = FilterCondition("x", op, literal^)
        var fields = List[DocumentField]()
        fields.append(DocumentField("x", json_value_from_python(row["value"])))
        var expected = Bool(py=row["matches"])
        assert_equal(matches_all(fields, [condition.clone()]), expected, String(i))
        var index = MetadataIndex()
        index.upsert(1, [fields[0].clone()])
        var hits = index.evaluate_condition(condition)
        assert_equal(index.contains_id(hits, 1), expected, String(i))
        var restored = MetadataIndex.decode_cache_payload(index.encode_cache_payload())
        var restored_hits = restored.evaluate_condition(condition)
        assert_equal(restored.contains_id(restored_hits, 1), expected)
        index.upsert(1, [DocumentField("x", PayloadValue.string("changed"))])
        index.upsert(1, fields^)
        var updated = index.evaluate_condition(condition)
        assert_equal(index.contains_id(updated, 1), expected)
        index.delete(1)
        assert_equal(index.evaluate_condition(condition).count(), 0)


def test_rich_value_resource_limits_and_atomic_path_failure() raises:
    var value = PayloadValue.null()
    for _ in range(PayloadValue.MAX_DEPTH):
        var next = List[PayloadValue]()
        next.append(value^)
        value = PayloadValue.array(next^)
    var too_deep = List[PayloadValue]()
    too_deep.append(value.clone())
    with assert_raises():
        _ = PayloadValue.array(too_deep^)
    var fields = List[DocumentField]()
    fields.append(DocumentField("max_depth", value^))
    _ = decode_payload(encode_payload(fields))

    var huge = List[PayloadValue]()
    for _ in range(PayloadValue.MAX_NODES):
        huge.append(PayloadValue.null())
    with assert_raises():
        _ = PayloadValue.array(huge^)
    var root = _json("{\"keep\": 1}")
    var original = root.clone()
    var path = String("a")
    for _ in range(PayloadValue.MAX_DEPTH):
        path += ".a"
    with assert_raises():
        payload_value_set(root, Optional(JsonPath.parse(path)), _json("{\"x\": 2}"))
    assert_true(root.same_representation(original))


def test_payload_v1_reader_and_v2_strict_corruption() raises:
    var flat = List[DocumentField]()
    flat.append(DocumentField("x", PayloadValue.integer(3)))
    var old = encode_payload(flat, version=1)
    var frozen_old = read_file_bytes("tests/fixtures/payload/v1.bin")
    assert_equal(len(old), len(frozen_old))
    for i in range(len(old)):
        assert_equal(old[i], frozen_old[i])
    assert_equal(old[0], UInt8(1))
    assert_equal(decode_payload(old^)[0].value.as_int(), Int64(3))
    var fields = List[DocumentField]()
    fields.append(DocumentField("x", _json("{\"a\": [null, -0.0, true, 18446744073709551615]}")))
    with assert_raises():
        _ = encode_payload(fields, version=1)
    var valid = encode_payload(fields, version=2)
    var frozen = read_file_bytes("tests/fixtures/payload/v2.bin")
    assert_equal(len(valid), len(frozen))
    for i in range(len(valid)):
        assert_equal(valid[i], frozen[i])
    for size in range(len(valid)):
        var truncated = List[UInt8]()
        for i in range(size):
            truncated.append(valid[i])
        with assert_raises():
            _ = decode_payload(truncated^)
    for offset in [4, 6, 15]:  # Version, flags, root value tag.
        var corrupt = valid.copy()
        corrupt[offset] = 99
        with assert_raises():
            _ = decode_payload(corrupt^)
    var trailing = valid.copy()
    trailing.append(0)
    with assert_raises():
        _ = decode_payload(trailing^)

    # Noncanonical duplicate object keys must not silently discard durable data.
    var writer = BinaryWriter()
    writer.write_u32(UInt32.MAX)
    writer.write_u16(2)
    writer.write_u16(0)
    writer.write_u32(1)
    writer.write_u16(1)
    writer.write_u8(120)
    writer.write_u8(7)
    writer.write_u32(2)
    for _ in range(2):
        writer.write_u32(1)
        writer.write_u8(97)
        writer.write_u8(5)
    with assert_raises():
        _ = decode_payload(writer.take_bytes())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
