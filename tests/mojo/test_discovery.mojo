from akasha.query.discovery import context_pair_loss, context_pair_rank, DiscoveryScores
from akasha import CollectionConfig, ContextPair, PersistentCollection, RecommendationExample
from akasha.common.config import MetricKind
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from akasha.query.discovery_scorer import PreparedDiscovery
from std.math import isnan
from std.memory import bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def _assert_score(actual: Float32, expected: UInt32) raises:
    if isnan(bitcast[DType.float32](expected)):
        assert_true(isnan(actual))
    else:
        assert_equal(bitcast[DType.uint32](actual), expected)


def test_discovery_reducers_match_verbatim_rust() raises:
    var fixture = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/qdrant-discovery/discovery.json").read())
    var samples = fixture["reductions"]
    for index in range(len(samples)):
        var sample = samples[index]
        var context = DiscoveryScores(False)
        var discover = DiscoveryScores(True)
        for i in range(len(sample["positive_bits"])):
            var positive = bitcast[DType.float32](UInt32(Int(py=sample["positive_bits"][i])))
            var negative = bitcast[DType.float32](UInt32(Int(py=sample["negative_bits"][i])))
            assert_equal(context_pair_rank(positive, negative), Int(py=sample["pairs"][i][0]))
            _assert_score(context_pair_loss(positive, negative), UInt32(Int(py=sample["pairs"][i][1])))
            context.add(positive, negative)
            discover.add(positive, negative)
        var target = bitcast[DType.float32](UInt32(Int(py=sample["target_bits"])))
        _assert_score(context.finish(), UInt32(Int(py=sample["context_bits"])))
        _assert_score(discover.finish(target), UInt32(Int(py=sample["discover_bits"])))


def _vector(raw: PythonObject, kind: String) raises -> VectorValue:
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
    return VectorValue.multivector[DType.float32](3, values^)


def test_discovery_prepared_scores_match_rust_vectors() raises:
    var fixture = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/qdrant-discovery/discovery.json").read())
    var samples = fixture["cases"]
    for index in range(len(samples)):
        var sample = samples[index]
        var kind = String(py=sample["kind"])
        var metric = String(py=sample["metric"])
        var field = VectorFieldSpec(2, "v", UInt8(0 if kind == "dense" else 1 if kind == "sparse" else 2), 0,
            UInt8(0 if metric == "dot" else 1 if metric == "l2" else 2), 0, Int(py=sample["dimension"]))
        var target = Optional[VectorValue]()
        if sample["target"] is not Python.none():
            target = Optional(_vector(sample["target"], kind))
        var positive = List[VectorValue]()
        var negative = List[VectorValue]()
        for i in range(len(sample["positive"])):
            positive.append(_vector(sample["positive"][i], kind))
            negative.append(_vector(sample["negative"][i], kind))
        var query = PreparedDiscovery(field, target, positive, negative)
        for i in range(len(sample["candidates"])):
            var candidate = _vector(sample["candidates"][i], kind)
            var actual = query.score(candidate, None)
            var expected = UInt32(Int(py=sample["expected"][i][1]))
            if bitcast[DType.uint32](actual) != expected:
                print("discovery fixture", index, "candidate", i, "kind", kind, "metric", metric)
            _assert_score(actual, expected)


def test_discovery_snapshot_ids_and_two_stage_graph() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-discover-"))
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    var config = CollectionConfig.defaults(3)
    config.ann_metric = MetricKind.dot()
    fields.append(VectorFieldSpec(2, "v", 0, 0, 0, 1, 3, Optional(config^)))
    var db = PersistentCollection.open_with_fields(path, fields^, maintenance_library_path="")
    var batch = List[PointMutation]()
    for id in range(128):
        var values: List[Float32] = [Float32(id % 31), Float32((id * 7) % 29), Float32((id * 11) % 23)]
        var updates: List[FieldUpdate] = [FieldUpdate.set(2, VectorValue.dense[DType.float32](values^))]
        batch.append(PointMutation(id, 1, updates^))
    _ = db.apply_point_batch(batch)
    var view = db.snapshot()
    var deletion: List[PointMutation] = [PointMutation.delete(64)]
    _ = db.apply_point_batch(deletion)
    db.close()
    var context: List[ContextPair] = [ContextPair(RecommendationExample.point(64), RecommendationExample.point(32))]
    var target = Optional(RecommendationExample.raw(VectorValue.dense[DType.float32]([2.5, 0, 1])))
    var exact = view.discover_field("v", target, context, 8)
    var ann = view.discover_field_reported("v", target, context, 8, approximate=True, ef_search=256)
    assert_equal(ann.reason, String("discovery_hnsw"))
    assert_equal(len(ann.results), len(exact))
    for i in range(len(exact)):
        assert_equal(ann.results[i].id, exact[i].id)
        assert_equal(ann.results[i].score, exact[i].score)
        assert_true(exact[i].id != 64 and exact[i].id != 32)
    var only_context = view.discover_field("v", None, context, 8)
    var context_ann = view.discover_field_reported("v", None, context, 8, approximate=True, ef_search=256)
    assert_equal(context_ann.reason, String("context_hnsw"))
    for i in range(len(only_context)):
        assert_equal(context_ann.results[i].id, only_context[i].id)
        assert_equal(context_ann.results[i].score, only_context[i].score)
    assert_equal(len(view.discover_field("missing", None, List[ContextPair](), 0)), 0)
    with assert_raises():
        _ = view.discover_field("v", None, List[ContextPair](), 1)
    view.close()
    Python.import_module("shutil").rmtree(path)


def test_discovery_retains_external_lookup_root_after_update_and_close() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-discovery-lookup-"))
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    fields.append(VectorFieldSpec(2, "v", 0, 0, 0, 0, 1))
    var db = PersistentCollection.open_with_fields(path + "/target", fields.copy(), maintenance_library_path="")
    var source = PersistentCollection.open_with_fields(path + "/source", fields^, maintenance_library_path="")
    var target_batch: List[PointMutation] = [PointMutation(1, 1, [FieldUpdate.set(2, VectorValue.dense[DType.float32]([3]))])]
    var source_batch: List[PointMutation] = [PointMutation(1, 1, [FieldUpdate.set(2, VectorValue.dense[DType.float32]([2]))])]
    _ = db.apply_point_batch(target_batch)
    _ = source.apply_point_batch(source_batch)
    var lookup = Optional(source.snapshot())
    var update: List[PointMutation] = [PointMutation(1, 1, [FieldUpdate.set(2, VectorValue.dense[DType.float32]([-2]))])]
    _ = source.apply_point_batch(update)
    var view = db.snapshot()
    source.close()
    db.close()
    var target = Optional(RecommendationExample.point(1))
    var hits = view.discover_field("v", target, List[ContextPair](), 1, lookup=lookup)
    assert_equal(hits[0].id, 1)
    var reducer = DiscoveryScores(True)
    assert_equal(hits[0].score, Float64(reducer.finish(6)))
    lookup.value().close()
    with assert_raises():
        _ = view.discover_field("v", target, List[ContextPair](), 1, lookup=lookup)
    assert_equal(len(view.discover_field("missing", target, List[ContextPair](), 0, lookup=lookup)), 0)
    view.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
