from akasha import CollectionConfig, FieldQuery, PersistentCollection
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from akasha.query.control import CancellationToken, QueryControl
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite


def test_sparse_to_native_maxsim_rerank_keeps_one_root_and_bounded_candidates() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-field-rerank-"
        )
    )
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "terms", 1, 0, 0, 2, 0))
    fields.append(VectorFieldSpec(3, "tokens", 2, 2, 0, 0, 2))
    var collection = PersistentCollection.open_with_fields(
        path, fields^, maintenance_library_path=""
    )
    var batch = List[PointMutation]()
    for i in range(6):
        var values: List[FieldUpdate] = [
            FieldUpdate.set(
                2, VectorValue.sparse([SparseElement(1, Float32(i + 1))])
            )
        ]
        if i < 5:
            var tokens = List[Float16]()
            if i != 4:
                tokens = [Float16(10 - i), Float16(0)]
            values.append(
                FieldUpdate.set(
                    3, VectorValue.multivector[DType.float16](2, tokens^)
                )
            )
        batch.append(PointMutation(i - 5, 1, values^))
    _ = collection.apply_point_batch(batch)
    var old = collection.snapshot()
    var queries: List[FieldQuery] = [
        FieldQuery("terms", VectorValue.sparse([SparseElement(1, 1)]))
    ]
    var final = Optional(
        FieldQuery("tokens", VectorValue.multivector[DType.float16](2, [1, 0]))
    )
    var result = old.search_fields_reported(queries, 2, fetch_k=3, rerank=final)
    assert_equal(result.reason, "field_rerank")
    assert_equal(len(result.results), 1)
    assert_equal(result.results[0].id, -2)
    assert_equal(result.results[0].score, Float64(7))
    assert_equal(result.stats.base_candidates, 3)
    assert_equal(result.stats.reranked_candidates, 1)
    var updates: List[PointMutation] = [
        PointMutation(-2, 2, []),
        PointMutation(
            9,
            1,
            [
                FieldUpdate.set(2, VectorValue.sparse([SparseElement(1, 100)])),
                FieldUpdate.set(
                    3, VectorValue.multivector[DType.float16](2, [50, 0])
                ),
            ],
        ),
    ]
    _ = collection.apply_point_batch(updates)
    var fresh = collection.snapshot()
    var new_result = fresh.search_fields(queries, 2, fetch_k=3, rerank=final)
    assert_equal(len(new_result), 1)
    assert_equal(new_result[0].id, 9)
    assert_equal(new_result[0].score, Float64(50))
    var token = CancellationToken()
    var limited = Optional(QueryControl(token, max_candidates=8))
    with assert_raises(contains="resource limit"):
        _ = fresh.search_fields(
            queries, 2, fetch_k=3, rerank=final, control=limited
        )
    token.cancel()
    var cancelled = Optional(QueryControl(token, max_candidates=100))
    with assert_raises(contains="cancelled"):
        _ = old.search_fields(
            queries, 2, fetch_k=3, rerank=final, control=cancelled
        )
    collection.close()
    var retained = old.search_fields(queries, 2, fetch_k=3, rerank=final)
    assert_equal(retained[0].id, -2)
    assert_equal(retained[0].score, Float64(7))
    old.close()
    fresh.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
