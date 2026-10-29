from akasha.query.mmr import MmrOptions, MmrSimilarity, maximal_marginal_relevance
from akasha.query.control import QueryControl
from akasha.query.field_mmr import MmrMatrix
from akasha.query.field_mmr import rerank_generation_mmr
from akasha.query.field_search import FieldSearchExecution, FieldSearchResult, field_exact_stats
from akasha import CollectionConfig, PersistentCollection
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import legacy_vector_fields
from akasha.query.recommendation_metrics import prepare_recommendation_vector, recommendation_similarity
from akasha.document.vector_value import VectorValue
from akasha.document.vector_schema import VectorFieldSpec
from akasha.index.sparse import SparseElement
from std.python import PythonObject
from std.python import Python
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


@fieldwise_init
struct FixtureMatrix(MmrSimilarity, Movable):
    var values: List[Float32]
    var size: Int

    def get_similarity(mut self, i: Int, j: Int, control: Optional[QueryControl]) raises -> Float32:
        return self.values[i * self.size + j]


def test_mmr_selection_matches_unedited_rust() raises:
    var fixture = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/qdrant-mmr/mmr.json").read())
    for key in ["reductions", "cases"]:
        var samples = fixture[key]
        for index in range(len(samples)):
            var sample = samples[index]
            var relevance = List[Float32]()
            var cells = List[Float32]()
            for i in range(len(sample["query_bits"])):
                relevance.append(bitcast[DType.float32](UInt32(Int(py=sample["query_bits"][i]))))
                for j in range(len(sample["query_bits"])):
                    cells.append(bitcast[DType.float32](UInt32(Int(py=sample["matrix_bits"][i][j]))))
            var matrix = FixtureMatrix(cells^, len(relevance))
            var selected = maximal_marginal_relevance(relevance, matrix, bitcast[DType.float32](UInt32(Int(py=sample["lambda_bits"]))), Int(py=sample["limit"]))
            assert_equal(len(selected), len(sample["expected"]), String(index))
            for i in range(len(selected)):
                assert_equal(selected[i], Int(py=sample["expected"][i][0]), String(index))


def test_mmr_options() raises:
    assert_equal(MmrOptions().candidate_count(7), 7)
    assert_equal(MmrOptions(0, 0).candidate_count(7), 0)
    assert_equal(MmrOptions(1, 16_384).candidate_count(7), 16_384)
    with assert_raises():
        _ = MmrOptions(-0.1).candidate_count(1)
    with assert_raises():
        _ = MmrOptions(1.1).candidate_count(1)
    with assert_raises():
        _ = MmrOptions(0.5, 16_385).candidate_count(1)
    with assert_raises():
        _ = MmrOptions().candidate_count(0)


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


def test_mmr_directional_vector_scores_match_rust() raises:
    var fixture = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/qdrant-mmr/mmr.json").read())
    var samples = fixture["cases"]
    for index in range(len(samples)):
        var sample = samples[index]
        var kind = String(py=sample["kind"])
        var metric = String(py=sample["metric"])
        var field = VectorFieldSpec(2, "v", UInt8(0 if kind == "dense" else (1 if kind == "sparse" else 2)), 0, UInt8(0 if metric == "dot" else (1 if metric == "l2" else 2)), UInt8(2 if kind == "sparse" else 0), 0 if kind == "sparse" else 3)
        var vectors = List[VectorValue]()
        for i in range(len(sample["candidates"])):
            var value = _vector(sample["candidates"][i], kind)
            vectors.append(prepare_recommendation_vector(value, field))
        var query = _vector(sample["query"], kind)
        var prepared = prepare_recommendation_vector(query, field)
        var matrix = MmrMatrix(vectors^, field)
        var relevance = List[Float32]()
        for i in range(len(matrix.vectors)):
            var score = recommendation_similarity(prepared, matrix.vectors[i], matrix.field)
            assert_equal(bitcast[DType.uint32](score), UInt32(Int(py=sample["query_bits"][i])), String(index))
            relevance.append(score)
            for j in range(len(matrix.vectors)):
                var pair_score = matrix.get_similarity(i, j, None)
                assert_equal(bitcast[DType.uint32](pair_score), UInt32(Int(py=sample["matrix_bits"][i][j])), String(index))
        var selected = maximal_marginal_relevance(relevance, matrix, bitcast[DType.float32](UInt32(Int(py=sample["lambda_bits"]))), Int(py=sample["limit"]))
        for i in range(len(selected)):
            assert_equal(selected[i], Int(py=sample["expected"][i][0]), String(index))


def test_mmr_captured_root_adapter_preserves_source_ids_and_original_scores() raises:
    var fixture = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/qdrant-mmr/mmr.json").read())
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-mmr-oracle-"))
    var samples = fixture["cases"]
    for index in range(len(samples)):
        var sample = samples[index]
        var kind = String(py=sample["kind"])
        var metric = String(py=sample["metric"])
        var field = VectorFieldSpec(2, "v", UInt8(0 if kind == "dense" else (1 if kind == "sparse" else 2)), 0, UInt8(0 if metric == "dot" else (1 if metric == "l2" else 2)), UInt8(2 if kind == "sparse" else 0), 0 if kind == "sparse" else 3)
        var fields = legacy_vector_fields(CollectionConfig.defaults(1))
        fields.append(field.copy())
        var collection = PersistentCollection.open_with_fields(path + "/" + String(index), fields^, maintenance_library_path="")
        var hits = List[FieldSearchResult]()
        var mutations = List[PointMutation]()
        for i in range(len(sample["candidates"])):
            var updates: List[FieldUpdate] = [FieldUpdate.set(2, _vector(sample["candidates"][i], kind))]
            mutations.append(PointMutation(i, 1, updates^))
            hits.append(FieldSearchResult(i, Float64((Float32(i) + Float32(0.25)) * Float32(-3))))
        _ = collection.apply_point_batch(mutations)
        var view = collection.snapshot()
        var root = view._acquire()
        collection.close()
        var execution = FieldSearchExecution(hits^, field_exact_stats(field), "test-source-candidates")
        var query = _vector(sample["query"], kind)
        var diversity = bitcast[DType.float32](UInt32(Int(py=sample["diversity_bits"])))
        var result = rerank_generation_mmr(root[], field, query, execution^, Int(py=sample["limit"]), diversity)
        assert_equal(len(result.results), len(sample["expected"]))
        for i in range(len(result.results)):
            assert_equal(result.results[i].id, Int(py=sample["expected"][i][0]), String(index))
            assert_equal(bitcast[DType.uint32](Float32(result.results[i].score)), UInt32(Int(py=sample["expected"][i][1])))
        view.close()
    Python.import_module("shutil").rmtree(path)


def test_mmr_public_snapshot_isolation_and_candidate_admission() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-mmr-view-"))
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    var field = VectorFieldSpec(2, "v", 0, 0, 0, 0, 1)
    fields.append(field.copy())
    var db = PersistentCollection.open_with_fields(path, fields^, maintenance_library_path="")
    for i in range(5):
        var updates: List[FieldUpdate] = [FieldUpdate.set(2, VectorValue.dense[DType.float32]([1]))]
        var batch: List[PointMutation] = [PointMutation(i, 1, updates^)]
        _ = db.apply_point_batch(batch)
    var old = db.snapshot()
    var updates: List[FieldUpdate] = [FieldUpdate.set(2, VectorValue.dense[DType.float32]([9]))]
    var batch: List[PointMutation] = [PointMutation(0, 1, updates^), PointMutation.delete(4)]
    _ = db.apply_point_batch(batch)
    var query = VectorValue.dense[DType.float32]([1])
    var current = db.search_field("v", query, 3, mmr=Optional(MmrOptions(0.5, 5)))
    assert_equal(current[0].id, 0)
    db.close()
    var hits = old.search_field("v", query, 3, mmr=Optional(MmrOptions(0.5, 5)))
    assert_equal(hits[0].id, 4)
    assert_equal(hits[1].id, 3)
    var by_id = old.search_field_by_id("v", 4, 3, mmr=Optional(MmrOptions(0.5, 5)))
    assert_equal(by_id[0].id, 3)
    var root = old._acquire()
    var candidates: List[FieldSearchResult] = [FieldSearchResult(2, 11), FieldSearchResult(2, 999), FieldSearchResult(999, 55), FieldSearchResult(1, 22)]
    var execution = FieldSearchExecution(candidates^, field_exact_stats(field), "test")
    var result = rerank_generation_mmr(root[], field, query, execution^, 5, 0.5)
    assert_equal(len(result.results), 2)
    assert_equal(result.results[0].id, 1)
    assert_equal(result.results[0].score, Float64(22))
    assert_equal(result.results[1].id, 2)
    assert_equal(result.results[1].score, Float64(11))
    old.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
