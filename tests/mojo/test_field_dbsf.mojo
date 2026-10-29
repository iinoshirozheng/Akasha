from akasha import CollectionConfig, FieldQuery, PersistentCollection
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite


def test_dbsf_keeps_captured_snapshot_after_mutation_and_close() raises:
    var tempfile = Python.import_module("tempfile")
    var path = String(py=tempfile.mkdtemp(prefix="akasha-field-dbsf-"))
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    fields.append(VectorFieldSpec(2, "v", 0, 0, 0, 0, 1))
    var collection = PersistentCollection.open_with_fields(
        path, fields^, maintenance_library_path=""
    )
    var updates: List[FieldUpdate] = [
        FieldUpdate.set(2, VectorValue.dense[DType.float32]([Float32(7)]))
    ]
    var batch: List[PointMutation] = [PointMutation(1, 1, updates^)]
    _ = collection.apply_point_batch(batch)
    var captured = collection.snapshot()
    var queries: List[FieldQuery] = [
        FieldQuery("v", VectorValue.dense[DType.float32]([Float32(1)]))
    ]
    var before = captured.search_fields_reported(queries, 1, fusion="dbsf")
    assert_equal(before.stats.metric_name, "dbsf")
    assert_equal(before.results[0].id, 1)
    assert_equal(before.results[0].score, Float64(0.5))
    var deletion: List[PointMutation] = [PointMutation.delete(1)]
    _ = collection.apply_point_batch(deletion)
    assert_equal(len(collection.search_fields(queries, 1, fusion="dbsf")), 0)
    collection.close()
    var retained = captured.search_fields(queries, 1, fusion="dbsf")
    assert_equal(retained[0].id, 1)
    assert_equal(retained[0].score, Float64(0.5))
    with assert_raises():
        _ = captured.search_fields(queries, 1, fusion="invalid")
    captured.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
