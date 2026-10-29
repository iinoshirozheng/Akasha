from akasha import CollectionConfig, PersistentCollection, RecommendationExample
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.query.recommendation import RecommendationScores, average_recommendation
from akasha.index.sparse import SparseElement
from std.python import Python, PythonObject
from std.memory import bitcast
from std.math import isfinite
from std.testing import assert_equal, assert_raises, TestSuite


def test_recommendation_strategies_and_snapshot() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-recommend-"))
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    fields.append(VectorFieldSpec(2, "v", 0, 0, 0, 0, 1))
    var collection = PersistentCollection.open_with_fields(path, fields^, maintenance_library_path="")
    for id in range(1, 5):
        var updates: List[FieldUpdate] = [FieldUpdate.set(2, VectorValue.dense[DType.float32]([Float32(id)]))]
        var batch: List[PointMutation] = [PointMutation(id, 1, updates^)]
        _ = collection.apply_point_batch(batch)
    var positive: List[RecommendationExample] = [RecommendationExample.point(4)]
    var negative: List[RecommendationExample] = [RecommendationExample.raw(VectorValue.dense[DType.float32]([1]))]
    var view = collection.snapshot()
    collection.close()
    var avg = view.recommend_field("v", positive, negative, 2)
    assert_equal(avg[0].id, 3)
    assert_equal(avg[0].score, Float64(21))
    var sums = view.recommend_field("v", positive, negative, 2, strategy="sum_scores")
    assert_equal(sums[0].id, 3)
    assert_equal(sums[0].score, Float64(9))
    var best = view.recommend_field("v", positive, negative, 2, strategy="best_score")
    assert_equal(best[0].id, 3)
    var empty = List[RecommendationExample]()
    with assert_raises():
        _ = view.recommend_field("v", empty, negative, 2)
    var negative_only = view.recommend_field("v", empty, negative, 2, strategy="sum_scores")
    assert_equal(negative_only[0].id, 1)
    assert_equal(negative_only[0].score, Float64(-1))
    view.close()
    Python.import_module("shutil").rmtree(path)


def test_recommendation_reducer_ties_and_overflow() raises:
    var reducer = RecommendationScores(True)
    reducer.add(2, False)
    reducer.add(2, True)
    assert_equal(reducer.finish(), -Float32(0.5) * (Float32(2) / Float32(3) + Float32(1)))
    var overflow = RecommendationScores(False)
    overflow.add(Float32(3e38), False)
    overflow.add(Float32(3e38), False)
    with assert_raises():
        _ = overflow.finish()


def test_recommendation_external_source_snapshot_survives_update_and_close() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-recommend-source-"))
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    fields.append(VectorFieldSpec(2, "v", 0, 0, 0, 0, 1))
    var target = PersistentCollection.open_with_fields(path + "/target", fields.copy(), maintenance_library_path="")
    var source = PersistentCollection.open_with_fields(path + "/source", fields^, maintenance_library_path="")
    var target_fields: List[FieldUpdate] = [FieldUpdate.set(2, VectorValue.dense[DType.float32]([10]))]
    var target_batch: List[PointMutation] = [PointMutation(4, 1, target_fields^)]
    _ = target.apply_point_batch(target_batch)
    var old_fields: List[FieldUpdate] = [FieldUpdate.set(2, VectorValue.dense[DType.float32]([2]))]
    var old_batch: List[PointMutation] = [PointMutation(4, 1, old_fields^)]
    _ = source.apply_point_batch(old_batch)
    var lookup = Optional(source.snapshot())
    var new_fields: List[FieldUpdate] = [FieldUpdate.set(2, VectorValue.dense[DType.float32]([7]))]
    var new_batch: List[PointMutation] = [PointMutation(4, 1, new_fields^)]
    _ = source.apply_point_batch(new_batch)
    var view = target.snapshot()
    source.close()
    target.close()
    var positive: List[RecommendationExample] = [RecommendationExample.point(4)]
    var negative = List[RecommendationExample]()
    var hits = view.recommend_field("v", positive, negative, 1, lookup=lookup, strategy="sum_scores")
    assert_equal(hits[0].id, 4)
    assert_equal(hits[0].score, Float64(20))
    lookup.value().close()
    with assert_raises():
        _ = view.recommend_field("v", positive, negative, 1, lookup=lookup)
    view.close()
    Python.import_module("shutil").rmtree(path)


def test_recommendation_reducers_match_verbatim_rust() raises:
    var builtins = Python.import_module("builtins")
    var fixture = Python.import_module("json").loads(builtins.open("tests/fixtures/qdrant-recommendation/recommendation.json").read())
    var samples = fixture["reductions"]
    for index in range(len(samples)):
        var sample = samples[index]
        var reducer = RecommendationScores(String(py=sample["strategy"]) == "best_score")
        for i in range(len(sample["positive_bits"])):
            reducer.add(bitcast[DType.float32](UInt32(Int(py=sample["positive_bits"][i]))), False)
        for i in range(len(sample["negative_bits"])):
            reducer.add(bitcast[DType.float32](UInt32(Int(py=sample["negative_bits"][i]))), True)
        var expected = UInt32(Int(py=sample["score_bits"]))
        if not isfinite(bitcast[DType.float32](expected)):
            with assert_raises():
                _ = reducer.finish()
        else:
            assert_equal(bitcast[DType.uint32](reducer.finish()), expected)


def _fixture_vector(raw: PythonObject, kind: String, dimension: Int) raises -> VectorValue:
    if kind == "sparse":
        var terms = List[SparseElement]()
        for i in range(len(raw)):
            terms.append(SparseElement(Int(py=raw[i][0]), Float32(py=raw[i][1])))
        return VectorValue.sparse(terms^)
    var values = List[Float32]()
    for i in range(len(raw)):
        if kind == "dense":
            values.append(Float32(py=raw[i]))
        else:
            for j in range(len(raw[i])):
                values.append(Float32(py=raw[i][j]))
    if kind == "dense":
        return VectorValue.dense[DType.float32](values^)
    return VectorValue.multivector[DType.float32](dimension, values^)


def test_average_transform_matches_rust_bits() raises:
    var fixture = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/qdrant-recommendation/recommendation.json").read())
    var samples = fixture["cases"]
    for index in range(len(samples)):
        var sample = samples[index]
        if String(py=sample["strategy"]) != "average_vector" or Bool(py=sample.__contains__("error")):
            continue
        if len(sample["positive_ids"]) or len(sample["negative_ids"]):
            continue
        var kind = String(py=sample["kind"])
        var dimension = Int(py=sample["dimension"])
        var positive = List[VectorValue]()
        var negative = List[VectorValue]()
        for i in range(len(sample["positive"])):
            positive.append(_fixture_vector(sample["positive"][i], kind, dimension))
        for i in range(len(sample["negative"])):
            negative.append(_fixture_vector(sample["negative"][i], kind, dimension))
        var result = average_recommendation(positive, negative)
        var expected = sample["average_bits"].split(",")
        if kind == "sparse":
            ref values = result.sparse_values()
            assert_equal(len(values), 0 if String(py=sample["average_bits"]) == "" else len(expected))
            for i in range(len(values)):
                var term = expected[i].split(":")
                assert_equal(values[i].term_id, Int(py=term[0]))
                assert_equal(bitcast[DType.uint32](values[i].weight), UInt32(Int(py=term[1])))
        elif kind == "dense":
            ref values = result.dense_values[DType.float32]()
            assert_equal(len(values), len(expected))
            for i in range(len(values)):
                assert_equal(bitcast[DType.uint32](values[i]), UInt32(Int(py=expected[i])))
        else:
            ref values = result.multivector_values[DType.float32]()
            assert_equal(len(values), len(expected))
            for i in range(len(values)):
                assert_equal(bitcast[DType.uint32](values[i]), UInt32(Int(py=expected[i])))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
