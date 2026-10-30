from akasha import PersistentCollection, CollectionConfig, PayloadUpdate
from akasha.compute.siphash import siphash24_zero, slice_numeric_id_hash
from akasha.document.record import DocumentField
from akasha.document.point_state import PointMutation, FieldUpdate
from akasha.document.vector_schema import FieldCatalog, VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.index.metadata import MetadataIndex
from akasha.query.point_condition import PointCondition, PointFilterContext
from akasha.query.payload_condition import _uint
from akasha.query.filter_ast import FilterExpression
from akasha.query.evaluator import matches_expression
from akasha.query.index_evaluator import evaluate_expression
from akasha.storage.point_store import PointStore
from bindings.payload_python import json_value_from_python
from test_payload_filter import _expression
from std.memory import ArcPointer
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def _schema() raises -> List[VectorFieldSpec]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    fields.append(VectorFieldSpec(2, "sparse", 1, 0, 0, 2, 0))
    fields.append(VectorFieldSpec(3, "v", 0, 0, 0, 0, 1))
    fields.append(VectorFieldSpec(4, "中文", 0, 0, 0, 0, 1))
    return fields^


def _parse(text: String) raises -> FilterExpression:
    return _expression(Python.import_module("json").loads(text))


def test_original_source_point_path_conditions_and_hashes() raises:
    var rows = Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-point-filter/filters.json").read())["cases"]
    var catalog = ArcPointer(FieldCatalog(1, 0, _schema()))
    var hashes = 0
    for i in range(len(rows)):
        var row = rows[i]
        if Bool(py=row.__contains__("error")):
            with assert_raises():
                _ = _expression(row["filter"])
            continue
        var expression = _expression(row["filter"])
        var fields = List[DocumentField]()
        for key in row["payload"]:
            fields.append(DocumentField(String(py=key), json_value_from_python(row["payload"][key])))
        var context = PointFilterContext(catalog=Optional(catalog.copy()))
        if not (row["id"] is Python.none()):
            context.id = Optional(Int(py=row["id"]))
        for name in row["vectors"]:
            var value = String(py=name)
            context.vector_ids.append(0 if value == "" else catalog[].field_at(catalog[].named_ordinal(value)).id)
        var expected = Bool(py=row["matches"])
        assert_equal(matches_expression(fields, expression, context), expected, "source point case " + String(i))
        assert_equal(matches_expression(fields, expression.clone(), context), expected, "clone point case " + String(i))
        if context.id and not expression.needs_vector_context():
            var index = MetadataIndex()
            index.upsert(context.id.value(), fields^)
            assert_equal(index.contains_id(evaluate_expression(index, expression), context.id.value()), expected, "metadata case " + String(i))
            index.delete(context.id.value())
            assert_equal(evaluate_expression(index, expression).count(), 0)
        if Bool(py=row.__contains__("hash_bytes")):
            var bytes = List[UInt8]()
            for byte in row["hash_bytes"]:
                bytes.append(UInt8(Int(py=byte)))
            var actual = siphash24_zero(bytes)
            assert_equal(actual, _uint(json_value_from_python(row["hash"])), "hash case " + String(i))
            if Bool(py=row.__contains__("id_hash")):
                assert_equal(actual, _uint(json_value_from_python(row["id_hash"])), "canonical ID " + String(i))
                var id = json_value_from_python(row["hash_id"])
                if not id.is_string():
                    var number = _uint(id)
                    assert_equal(slice_numeric_id_hash(number), actual)
            hashes += 1
    assert_equal(len(rows), 12656)
    assert_equal(hashes, 2187)


def test_clone_revalidates_mutated_native_predicates_and_signed_id_contract() raises:
    var json = Python.import_module("json")
    var condition = PointCondition(json_value_from_python(json.loads('{"kind":"has_id","ids":[-1]}')))
    var expression = FilterExpression.point(condition.copy())
    condition.ids[-2] = True
    var cloned = expression.clone()
    assert_true(matches_expression([], cloned, PointFilterContext(Optional(-1))))
    assert_equal(matches_expression([], cloned, PointFilterContext(Optional(-2))), False)
    var negative = -1
    assert_equal(slice_numeric_id_hash(UInt64(negative)), slice_numeric_id_hash(UInt64.MAX))
    var slice = PointCondition(json_value_from_python(json.loads('{"kind":"slice","total":3,"index":1}')))
    slice.total = 0
    with assert_raises():
        _ = FilterExpression.point(slice.copy())
    slice.total = 1
    with assert_raises():
        _ = FilterExpression.point(slice.copy())
    for raw in ['{"kind":"has_id","ids":[9223372036854775808]}',
                '{"kind":"has_id","ids":["550e8400-e29b-41d4-a716-446655440000"]}',
                '{"kind":"has_vector","field_id":-1}',
                '{"kind":"has_vector","field_id":4294967296}',
                '{"kind":"has_vector","field_id":1,"name":""}',
                '{"kind":"has_vector"}']:
        with assert_raises():
            _ = _parse(raw)


def test_slice_partition_and_correlated_subsets() raises:
    for id in range(-512, 1024):
        var hash = slice_numeric_id_hash(UInt64(id))
        var selected = 0
        for index in range(7):
            var condition = _parse('{"kind":"slice","total":7,"index":' + String(index) + '}')
            selected += Int(matches_expression([], condition, PointFilterContext(Optional(id))))
        assert_equal(selected, 1)
        if hash % 4 == 0:
            assert_equal(hash % 2, UInt64(0))


def test_authoritative_vector_presence_metadata_snapshots_mutations_and_reopen() raises:
    var temporary = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=temporary.name)
    var collection = PersistentCollection.open_with_fields(path, _schema(), maintenance_library_path="")
    var mutations: List[PointMutation] = [
        PointMutation(-1, 1, [FieldUpdate.set(0, VectorValue.dense[DType.float32]([1])),
            FieldUpdate.set(1, VectorValue.sparse([])), FieldUpdate.set(3, VectorValue.dense[DType.float32]([2]))]),
        PointMutation(2, 1, [FieldUpdate.set(0, VectorValue.dense[DType.float32]([2]))]),
        PointMutation(3, 1, [FieldUpdate.set(3, VectorValue.dense[DType.float32]([3]))]),
        PointMutation(4, 1, []),
    ]
    _ = collection.apply_point_batch(mutations)
    var has_vector = _parse('{"kind":"has_vector","name":"v"}')
    var has_sparse = _parse('{"kind":"has_vector","field_id":1}')
    var has_dense = _parse('{"kind":"has_vector","name":""}')
    assert_equal(collection.metadata_match_count(has_vector), 2)
    assert_equal(collection.metadata_match_count(has_sparse), 1)
    assert_equal(collection.metadata_match_count(has_dense), 2)
    assert_equal(collection.metadata_match_count(_parse('{"kind":"has_id","ids":[-1,3,4]}')), 3)
    var snapshot = collection.snapshot()
    var query = VectorValue.dense[DType.float32]([1])
    assert_equal(snapshot.search_field("v", query, 10, Optional(has_dense.clone()))[0].id, -1)
    assert_equal(collection.search_dot_where([1], 10, has_sparse)[0].id, -1)
    collection.flush()
    _ = collection.apply_point_batch([PointMutation(-1, 3, [FieldUpdate.remove(1), FieldUpdate.remove(3)])])
    assert_equal(collection.metadata_match_count(has_vector), 1)
    assert_equal(collection.metadata_match_count(has_sparse), 0)
    assert_equal(len(snapshot.search_field("v", query, 10, Optional(has_vector.clone()))), 2)
    var result = collection.apply_payload_update(PayloadUpdate.set(["marked"], [json_value_from_python(PythonObject(True))]), expression=Optional(has_vector.clone()))
    assert_equal(result.count, 1)
    assert_true(collection.get_point(3).value().payload()[0].value.as_bool())
    collection.close()
    var reopened = PersistentCollection.open(path, 1, maintenance_library_path="")
    assert_equal(reopened.metadata_match_count(has_vector), 1)
    assert_equal(reopened.metadata_match_count(has_sparse), 0)
    reopened.flush()
    reopened.close()
    var again = PersistentCollection.open(path, 1, maintenance_library_path="")
    assert_equal(again.metadata_match_count(has_vector), 1)
    assert_equal(again.metadata_match_count(has_dense), 2)
    assert_equal(len(snapshot.search_field("v", query, 10, Optional(has_vector.clone()))), 2)
    snapshot.close()
    again.close()
    temporary.cleanup()


def test_point_store_independent_search_uses_id_and_named_presence() raises:
    var temporary = Python.import_module("tempfile").TemporaryDirectory()
    var store = PointStore.open(String(py=temporary.name), _schema())
    _ = store.apply_batch([PointMutation(-1, 1, [FieldUpdate.set(3, VectorValue.dense[DType.float32]([2]))])])
    var filter = _parse('{"kind":"all","children":[{"kind":"has_id","ids":[-1]},{"kind":"has_vector","name":"v"}]}')
    assert_equal(store.search("v", VectorValue.dense[DType.float32]([1]), 1, Optional(filter^))[0].id, -1)
    store.close()
    temporary.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
