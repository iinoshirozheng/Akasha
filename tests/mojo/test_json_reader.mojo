from akasha.document.json_reader import parse_json, parse_json_bytes
from akasha.document.value import PayloadValue
from akasha.document.codec import encode_payload, decode_payload
from akasha.document.record import DocumentField
from akasha import PersistentCollection
from akasha.storage.filesystem import read_file_bytes
from std.memory import bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def _compare(actual: PayloadValue, expected: PythonObject) raises:
    var kind = Int(py=expected[0])
    assert_equal(Int(actual.kind()), kind)
    if kind == 1:
        assert_equal(actual.as_string(), String(py=expected[1]))
    elif kind == 2:
        assert_equal(String(actual.as_int()), String(py=expected[1]))
    elif kind == 8:
        assert_equal(String(actual.as_uint()), String(py=expected[1]))
    elif kind == 3:
        assert_equal(String(bitcast[DType.uint64](actual.as_float())), String(py=expected[1]))
    elif kind == 4:
        assert_equal(actual.as_bool(), Bool(py=expected[1]))
    elif kind == 6 or kind == 7:
        var children = actual.children()
        assert_equal(len(children), len(expected[1]))
        if kind == 7:
            var keys = actual.keys()
            for i in range(len(children)):
                assert_equal(keys[i], String(py=expected[1][i][0]))
                _compare(children[i], expected[1][i][1])
        else:
            for i in range(len(children)):
                _compare(children[i], expected[1][i])


def test_original_serde_json_reference() raises:
    var pathlib = Python.import_module("pathlib")
    var json = Python.import_module("json")
    var builtins = Python.import_module("builtins")
    var cases = json.loads(pathlib.Path("tests/fixtures/json-value/cases.json").read_text())
    var passed = 0
    var rejected = 0
    for item in cases:
        var bytes = List[UInt8]()
        for byte in builtins.bytes.fromhex(item["hex"]):
            bytes.append(UInt8(Int(py=byte)))
        if Bool(py=item.__contains__("error")):
            var failed = False
            try:
                _ = parse_json_bytes(Span(bytes))
            except:
                failed = True
            if not failed:
                print("unexpected accept", item["hex"])
            assert_true(failed)
            rejected += 1
        else:
            try:
                var value = parse_json_bytes(Span(bytes))
                _compare(value, item["value"])
                var encoded = encode_payload([DocumentField("json", value.clone())])
                var decoded = decode_payload(encoded^)
                _compare(decoded[0].value, item["value"])
            except err:
                print("reference mismatch", item["hex"], item["value"])
                raise err
            passed += 1
    assert_equal(passed, 3063)
    assert_equal(rejected, 2567)


def test_source_signed_zero_integer_bounds_and_duplicates() raises:
    var zero = parse_json("-0")
    assert_equal(bitcast[DType.uint64](zero.as_float()), UInt64(1) << 63)
    var minimum = parse_json("-9223372036854775808")
    assert_equal(minimum.as_int(), Int64.MIN)
    var maximum = parse_json("18446744073709551615")
    assert_equal(maximum.as_uint(), UInt64.MAX)
    var object = parse_json('{"a":1,"b":2,"a":3}')
    var keys = object.keys()
    assert_equal(keys[0], "a")
    assert_equal(keys[1], "b")
    assert_equal(object.get_key("a").value().as_int(), Int64(3))


def test_all_truncations_of_nested_escape_input() raises:
    var input = '{"key":[true,null,"\\uD834\\uDD1E",{"n":-1.2345e67}]}'
    var bytes = input.as_bytes()
    for end in range(len(bytes)):
        with assert_raises():
            _ = parse_json_bytes(bytes[:end])
    _ = parse_json(input)


def test_depth_and_source_bounds() raises:
    var text = String("0")
    for _ in range(64):
        text = "[" + text + "]"
    var value = parse_json(text)
    assert_equal(value._depth, 64)
    with assert_raises():
        _ = parse_json("[" + text + "]")
    var bytes = List[UInt8](length=PayloadValue.MAX_BYTES + 1, fill=32)
    with assert_raises():
        _ = parse_json_bytes(Span(bytes))


def test_parsed_node_budget_includes_discarded_duplicates() raises:
    var text = String('{"x":0')
    for _ in range(PayloadValue.MAX_NODES - 1):
        text += ',"x":0'
    text += "}"
    with assert_raises():
        _ = parse_json(text)


def test_owned_value_survives_source_reuse() raises:
    var text = String('{"x":["retained",null]}')
    var value = parse_json(text)
    text = "overwritten"
    assert_equal(text, "overwritten")
    var array = value.get_key("x")
    var string = array.value().get_index(0)
    assert_equal(string.value().as_string(), "retained")


def test_parsed_payload_wal_snapshot_checkpoint_and_rejected_write() raises:
    var temporary = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=temporary.name)
    var original = parse_json('{"":[],"nul\\u0000key":[null,-0,18446744073709551615],"a":1,"a":2}')
    var collection = PersistentCollection.open(path, 1)
    collection.upsert_document(1, [1], [DocumentField("json", original.clone())])
    var wal = read_file_bytes(path + "/wal.bin")
    with assert_raises():
        collection.upsert_document(1, [2], [DocumentField("json", parse_json('{"a":1,}'))])
    assert_equal(collection.last_sequence(), UInt64(1))
    assert_equal(read_file_bytes(path + "/wal.bin"), wal)
    collection.close()
    var reopened = PersistentCollection.open(path, 1)
    assert_true(reopened.get(1).value().get_field("json").value().same_representation(original))
    var snapshot = reopened.snapshot()
    var updated = parse_json('["changed",{"integer":-9223372036854775808,"float":1e-320}]')
    reopened.upsert_document(1, [3], [DocumentField("json", updated.clone())])
    reopened.flush()
    reopened.close()
    assert_true(snapshot.get(1).value().get_field("json").value().same_representation(original))
    snapshot.close()
    var restored = PersistentCollection.open(path, 1)
    assert_true(restored.get(1).value().get_field("json").value().same_representation(updated))
    restored.close()
    temporary.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
