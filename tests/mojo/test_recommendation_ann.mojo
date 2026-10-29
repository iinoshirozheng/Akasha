from akasha import CollectionConfig, PersistentCollection, RecommendationExample
from akasha.common.config import MetricKind
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from std.python import Python
from std.testing import assert_equal, TestSuite


def test_recommendation_graph_uses_retained_snapshot_and_excludes_source() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-recommend-ann-"))
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    var config = CollectionConfig.defaults(3)
    config.ann_metric = MetricKind.dot()
    fields.append(VectorFieldSpec(2, "v", 0, 0, 0, 1, 3, Optional(config^)))
    var collection = PersistentCollection.open_with_fields(path, fields^, maintenance_library_path="")
    var batch = List[PointMutation]()
    for id in range(128):
        var values: List[Float32] = [Float32(id % 31), Float32((id * 7) % 29), Float32((id * 11) % 23)]
        var updates: List[FieldUpdate] = [FieldUpdate.set(2, VectorValue.dense[DType.float32](values^))]
        batch.append(PointMutation(id, 1, updates^))
    _ = collection.apply_point_batch(batch)
    var view = collection.snapshot()
    collection.close()
    var positive: List[RecommendationExample] = [
        RecommendationExample.point(64),
        RecommendationExample.raw(VectorValue.dense[DType.float32]([2.5, 0, 1])),
    ]
    var negative: List[RecommendationExample] = [RecommendationExample.raw(VectorValue.dense[DType.float32]([1, 2, 0]))]
    for strategy in [String("average_vector"), String("best_score"), String("sum_scores")]:
        var exact = view.recommend_field("v", positive, negative, 8, strategy=strategy)
        var ann = view.recommend_field_reported("v", positive, negative, 8, strategy=strategy, approximate=True, ef_search=256)
        assert_equal(ann.reason, String("recommendation_hnsw"))
        assert_equal(len(ann.results), len(exact))
        for i in range(len(exact)):
            assert_equal(ann.results[i].id, exact[i].id)
            assert_equal(ann.results[i].score, exact[i].score)
            assert_equal(ann.results[i].id == 64, False)
    view.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
