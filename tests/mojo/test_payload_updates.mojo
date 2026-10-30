from akasha import PersistentCollection, PayloadUpdate, PayloadValue, DocumentField
from akasha.document.json_path import JsonPath
from akasha.document.codec import encode_payload
from akasha.query.filter_ast import FilterExpression, FilterCondition
from akasha.storage.filesystem import read_file_bytes
from bindings.payload_python import json_value_from_python
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def _fields(raw: PythonObject) raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    for key in raw:
        fields.append(DocumentField(String(py=key), json_value_from_python(raw[key])))
    return fields^


def _valid_names(raw: PythonObject) raises -> Bool:
    for key in raw:
        if len(key) == 0 or Bool(py=key.__contains__("\0")):
            return False
    return True


def test_document_root_operations_match_original_source_cases() raises:
    var rows = Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-payload-values/values.json").read())["cases"]
    var count = 0
    for row in rows:
        var op = String(py=row["op"])
        if op == "get" or not _valid_names(row["input"]) or not _valid_names(row["output"]):
            continue
        var path = Optional[JsonPath]()
        if not (row["path"] is Python.none()):
            path = Optional(JsonPath.parse(String(py=row["path"])))
        if op == "set" and not path and not _valid_names(row["source"]):
            continue
        var operation: PayloadUpdate
        if op == "set":
            var source = json_value_from_python(row["source"])
            operation = PayloadUpdate.set(source.keys(), source.children(), path^)
        else:
            operation = PayloadUpdate.delete([path.value().copy()])
        var fields = _fields(row["input"])
        var expected = _fields(row["output"])
        assert_equal(encode_payload(operation.apply(fields)), encode_payload(expected), String(count))
        count += 1
    assert_equal(count, 1644)


def test_root_depth_boundary_and_overwrite_null() raises:
    var deep = PayloadValue.null()
    for _ in range(64):
        deep = PayloadValue.array([deep^])
    var update = PayloadUpdate.set(["deep"], [deep^])
    var fields = update.apply(List[DocumentField]())
    _ = encode_payload(fields)
    var other = PayloadUpdate.set(["other"], [PayloadValue.integer(9)])
    fields = other.apply(fields)
    assert_equal(fields[0].value._depth, 64)
    var replacement = PayloadUpdate.overwrite(["null"], [PayloadValue.null()])
    fields = replacement.apply(fields)
    assert_equal(len(fields), 1)
    assert_true(fields[0].value.is_null())
    var merge = PayloadUpdate.set(["null"], [PayloadValue.null()])
    fields = merge.apply(fields)
    assert_equal(len(fields), 0)


def test_collection_payload_batch_preserves_vectors_snapshot_and_recovery() raises:
    var temporary = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=temporary.name)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert_document(2, [1, 2], [DocumentField("group", PayloadValue.integer(1))])
    collection.upsert_document(1, [3, 4], [DocumentField("group", PayloadValue.integer(1))])
    var old = collection.snapshot()
    var address = old.get_point(1).value().field_at(0).address()
    var expression = FilterExpression.condition(FilterCondition.equal("group", PayloadValue.integer(1)))
    var update = PayloadUpdate.set(["name"], [PayloadValue.string("new")])
    var result = collection.apply_payload_update(update, expression=Optional(expression^))
    assert_equal(result.count, 2)
    assert_equal(collection.get_point(1).value().sequence, result.first_sequence)
    assert_equal(collection.get_point(1).value().field_at(0).address(), address)
    assert_equal(len(old.get(1).value().fields), 1)
    assert_equal(len(collection.get(1).value().fields), 2)
    var wal = read_file_bytes(path + "/wal.bin")
    with assert_raises():
        _ = collection.apply_payload_update(PayloadUpdate.clear(), points=Optional[List[Int]]([1, 404]))
    assert_equal(collection.last_sequence(), result.last_sequence)
    assert_equal(read_file_bytes(path + "/wal.bin"), wal)
    var empty = collection.apply_payload_update(PayloadUpdate.clear(), points=Optional(List[Int]()))
    assert_equal(empty.count, 0)
    assert_equal(empty.first_sequence, UInt64(0))
    assert_equal(empty.last_sequence, result.last_sequence)
    old.close()
    collection.close()
    var reopened = PersistentCollection.open(path, 2)
    assert_equal(reopened.get(1).value().vector, [Float32(3), 4])
    assert_equal(reopened.get(2).value().get_field("name").value().as_string(), "new")
    var cleared = reopened.apply_payload_update(PayloadUpdate.clear(), points=Optional[List[Int]]([1, 1]))
    assert_equal(cleared.count, 1)
    reopened.flush()
    reopened.close()
    var final_open = PersistentCollection.open(path, 2)
    assert_equal(len(final_open.get(1).value().fields), 0)
    final_open.close()
    temporary.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
