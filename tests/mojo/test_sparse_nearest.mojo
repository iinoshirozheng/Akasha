from akasha.compute.field_metrics import score_vector_field
from akasha.document.point_state import PointField, PointState
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.field_artifacts import FieldRow
from akasha.index.field_sparse import FieldSparseIndex
from akasha.index.sparse import SparseElement, SparseIndex
from akasha.index.sparse_search import search_sparse_postings
from akasha.query.field_search import search_point_field
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.recommendation_metrics import recommendation_similarity
from std.memory import ArcPointer, bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, TestSuite


def _values(raw: PythonObject) raises -> List[SparseElement]:
    var result = List[SparseElement]()
    for i in range(len(raw)):
        result.append(SparseElement(Int(py=raw[i][0]), Float32(py=raw[i][1])))
    return result^


def test_all_source_paths_and_mutable_index_match_rust_bits() raises:
    var builtins = Python.import_module("builtins")
    var samples = Python.import_module("json").loads(builtins.open("tests/fixtures/qdrant-sparse-nearest/search.json").read())["cases"]
    for sample_index in range(len(samples)):
        var sample = samples[sample_index]
        var label = String(py=sample["name"])
        var size = Int(py=sample["size"])
        var index = FieldSparseIndex()
        var mutable = SparseIndex()
        for row in range(size):
            var values = _values(sample["points"].get(String(row), builtins.list()))
            index.add(FieldRow(row, 0, row), values)
            mutable.upsert(row, values)
        var allowed = List[Bool](length=size, fill=True)
        var filtered = Bool(py=builtins.isinstance(sample["allowed"], builtins.list))
        if filtered:
            allowed = List[Bool](length=size, fill=False)
            for i in range(len(sample["allowed"])):
                allowed[Int(py=sample["allowed"][i])] = True
        var query = _values(sample["query"])
        var plain = String(py=sample["mode"]) == "plain"
        var expected = sample["expected"]
        var hits = search_sparse_postings(ArcPointer(index^), query, allowed, Int(py=sample["k"]), plain)
        assert_equal(len(hits.results), len(expected), label)
        for i in range(len(expected)):
            assert_equal(hits.results[i].id, Int(py=expected[i][0]), label)
            assert_equal(bitcast[DType.uint32](hits.results[i].score), UInt32(Int(py=expected[i][1])), label)
        if not plain and not filtered:
            var direct = mutable.search_dot(query, Int(py=sample["k"]))
            assert_equal(len(direct), len(expected), label)
            for i in range(len(expected)):
                assert_equal(direct[i].id, Int(py=expected[i][0]), label)
                assert_equal(bitcast[DType.uint32](direct[i].score), UInt32(Int(py=expected[i][1])), label)


def test_point_store_query_adapter_matches_plain_and_indexed_oracle() raises:
    var builtins = Python.import_module("builtins")
    var samples = Python.import_module("json").loads(builtins.open("tests/fixtures/qdrant-sparse-nearest/search.json").read())["cases"]
    var field = VectorFieldSpec(2, "s", 1, 0, 0, 2, 0)
    for sample_index in range(len(samples)):
        var sample = samples[sample_index]
        var size = Int(py=sample["size"])
        if size >= 5_000:
            continue
        var plain = String(py=sample["mode"]) == "plain"
        var filtered = Bool(py=builtins.isinstance(sample["allowed"], builtins.list))
        if not plain and filtered:
            continue
        var allowed = List[Bool](length=size, fill=True)
        if filtered:
            allowed = List[Bool](length=size, fill=False)
            for i in range(len(sample["allowed"])):
                allowed[Int(py=sample["allowed"][i])] = True
        var points = List[PointState]()
        for row in range(size):
            var values = _values(sample["points"].get(String(row), builtins.list()))
            points.append(PointState.live(row, 1, 0,
                [PointField(2, VectorValue.sparse(values^))],
                [DocumentField("keep", PayloadValue.boolean(allowed[row]))]))
        # Missing fields and tombstones never enter sparse postings.
        points.append(PointState.live(size, 1, 0, [], []))
        points.append(PointState.deleted(size + 1, 2))
        var expression = Optional[FilterExpression]()
        if plain:
            expression = Optional(FilterExpression.condition(FilterCondition.equal("keep", PayloadValue.boolean(True))))
        var query = VectorValue.sparse(_values(sample["query"]))
        var hits = search_point_field(Span(points), field, query, Int(py=sample["k"]), expression)
        var expected = sample["expected"]
        var label = String(py=sample["name"])
        assert_equal(len(hits), len(expected), label)
        for i in range(len(expected)):
            assert_equal(hits[i].id, Int(py=expected[i][0]), label)
            assert_equal(bitcast[DType.uint32](Float32(hits[i].score)), UInt32(Int(py=expected[i][1])), label)


def test_sparse_raw_and_recommendation_scorers_round_products() raises:
    var field = VectorFieldSpec(2, "s", 1, 0, 0, 2, 0)
    var stored = VectorValue.sparse([SparseElement(1, 1.0000001192092896), SparseElement(2, -1.0000001192092896)])
    var query = VectorValue.sparse([SparseElement(1, 0.9999998807907104), SparseElement(2, 0.9999998807907104)])
    assert_equal(score_vector_field(query, stored, field), Float64(0))
    assert_equal(recommendation_similarity(query, stored, field), Float32(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
