from akasha import CollectionConfig, FieldQuery, PersistentCollection
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.query.fusion import rrf_position_score
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite


def test_weighted_snapshot_retains_root_and_validates_options() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-weighted-rrf-"))
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
    var values: List[Float32] = [3]
    var weights = Optional(values^)
    var deletion: List[PointMutation] = [PointMutation.delete(1)]
    _ = collection.apply_point_batch(deletion)
    assert_equal(len(collection.search_fields(queries, 1, weights=weights)), 0)
    collection.close()
    var retained = captured.search_fields_reported(queries, 1, weights=weights)
    assert_equal(retained.results[0].id, 1)
    assert_equal(retained.results[0].score, Float64(rrf_position_score(0, 2, 3)))
    assert_equal(retained.stats.metric_name, "rrf")
    with assert_raises():
        _ = captured.search_fields(queries, 1, fusion="dbsf", weights=weights)
    with assert_raises():
        _ = captured.search_fields(queries, 1, weights=Optional(List[Float32]()))
    captured.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
