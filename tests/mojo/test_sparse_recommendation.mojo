from akasha import CollectionConfig, PersistentCollection, RecommendationExample
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.index.field_artifacts import FieldRow
from akasha.index.field_sparse import FieldSparseIndex
from akasha.index.sparse import SparseElement
from akasha.index.sparse_search import search_sparse_postings
from akasha.query.control import CancellationToken, QueryControl
from std.memory import ArcPointer, bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_raises, TestSuite
from std.time import perf_counter_ns


def _sparse_values(raw: PythonObject) raises -> List[SparseElement]:
    var values = List[SparseElement]()
    for i in range(len(raw)):
        values.append(SparseElement(Int(py=raw[i][0]), Float32(py=raw[i][1])))
    return values^


def test_sparse_search_matches_unedited_upstream_methods() raises:
    var builtins = Python.import_module("builtins")
    var samples = Python.import_module("json").loads(builtins.open("tests/fixtures/qdrant-recommendation/sparse-search.json").read())["cases"]
    for sample_index in range(len(samples)):
        var sample = samples[sample_index]
        var index = FieldSparseIndex()
        var size = Int(py=sample["size"])
        for row in range(size):
            var values = _sparse_values(sample["points"].get(String(row), builtins.list()))
            index.add(FieldRow(row, 0, row), values)
        var owner = ArcPointer(index^)
        var allowed = List[Bool](length=size, fill=True)
        if Bool(py=builtins.isinstance(sample["allowed"], builtins.list)):
            allowed = List[Bool](length=size, fill=False)
            for i in range(len(sample["allowed"])):
                allowed[Int(py=sample["allowed"][i])] = True
        var query = _sparse_values(sample["query"])
        var result = search_sparse_postings(owner, query, allowed, Int(py=sample["k"]), String(py=sample["mode"]) == "plain")
        var expected = sample["expected"]
        assert_equal(len(result.results), len(expected), String(py=sample["name"]))
        for i in range(len(expected)):
            assert_equal(result.results[i].id, Int(py=expected[i][0]))
            assert_equal(bitcast[DType.uint32](result.results[i].score), UInt32(Int(py=expected[i][1])))


def test_sparse_controls_bounds_and_nonfinite_admission() raises:
    var index = FieldSparseIndex()
    index.add(FieldRow(1, 0, 0), [SparseElement(1, Float32(3e38))])
    index.add(FieldRow(2, 0, 1), [SparseElement(1, 1)])
    var owner = ArcPointer(index^)
    var query: List[SparseElement] = [SparseElement(1, 2)]
    for plain in [False, True]:
        with assert_raises(contains="finite"):
            _ = search_sparse_postings(owner, query, [True, True], 2, plain)
        var filtered = search_sparse_postings(owner, query, [False, True], 2, plain)
        assert_equal(len(filtered.results), 1)
        assert_equal(filtered.results[0].id, 2)
        var token = CancellationToken()
        token.cancel()
        with assert_raises(contains="cancel"):
            _ = search_sparse_postings(owner, [], [True, True], 1, plain, Optional(QueryControl(token, max_candidates=2)))
        var deadline = QueryControl(CancellationToken(), max_candidates=2, deadline_ns=perf_counter_ns() - 1)
        with assert_raises(contains="deadline"):
            _ = search_sparse_postings(owner, query, [True, True], 1, plain, Optional(deadline^))
    with assert_raises(contains="admission"):
        _ = search_sparse_postings(owner, query, [True], 1, False)
    with assert_raises(contains="positive"):
        _ = search_sparse_postings(owner, query, [True, True], 0, False)


def test_sparse_recommendation_snapshot_after_writer_close() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-sparse-recommend-"))
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    fields.append(VectorFieldSpec(2, "terms", 1, 0, 0, 2, 0))
    var collection = PersistentCollection.open_with_fields(path, fields^, maintenance_library_path="")
    var batch = List[PointMutation]()
    for id in range(1, 5):
        var updates: List[FieldUpdate] = [FieldUpdate.set(2, VectorValue.sparse([SparseElement(1, Float32(id))]))]
        batch.append(PointMutation(id, 1, updates^))
    _ = collection.apply_point_batch(batch)
    collection.flush()
    var view = collection.snapshot()
    collection.close()
    var positive: List[RecommendationExample] = [RecommendationExample.point(4)]
    var negative: List[RecommendationExample] = [RecommendationExample.raw(VectorValue.sparse([SparseElement(1, 1)]))]
    for strategy in [String("average_vector"), String("best_score"), String("sum_scores")]:
        var exact = view.recommend_field("terms", positive, negative, 3, strategy=strategy)
        var indexed = view.recommend_field_reported("terms", positive, negative, 3, strategy=strategy, approximate=True)
        assert_equal(indexed.reason, String("recommendation_sparse_plain") if strategy == "average_vector" else String("recommendation_sparse_scored"))
        assert_equal(len(exact), len(indexed.results))
        for i in range(len(exact)):
            assert_equal(indexed.results[i].id, exact[i].id)
            assert_equal(indexed.results[i].score, exact[i].score)
    var root = view._acquire()
    assert_equal(root[].field_sparse[].get(2)[].build_count, 1)
    view.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
