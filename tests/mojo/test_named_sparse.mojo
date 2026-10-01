from akasha import CollectionConfig, FieldQuery, PersistentCollection
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.query.control import CancellationToken, QueryControl
from akasha.index.artifact_state import ARTIFACT_FAILED, ARTIFACT_READY
from std.time import perf_counter_ns
from std.testing import assert_raises, assert_true
from max.algorithm import parallelize
from akasha.query.filter_ast import FilterCondition, FilterExpression
from std.python import Python
from std.testing import assert_equal, TestSuite


def test_named_postings_preserve_f64_zero_negative_and_root_visibility() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-named-sparse-"
        )
    )
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "terms", 1, 0, 0, 2, 0))
    fields.append(VectorFieldSpec(3, "other", 1, 0, 0, 2, 0))
    var collection = PersistentCollection.open_with_fields(
        path, fields.copy(), maintenance_library_path=""
    )
    var batch = List[PointMutation]()
    var ids: List[Int] = [-8, -3, 5, 10, 0]
    for i in range(len(ids)):
        var values = List[SparseElement]()
        if i == 0:
            values = [
                SparseElement(1, 1e10),
                SparseElement(2, 1),
                SparseElement(3, -1e10),
            ]
        elif i == 2:
            values = [SparseElement(99, 2)]
        elif i == 3:
            values = [SparseElement(1, -1)]
        var updates = List[FieldUpdate]()
        if i != 4:
            updates.append(FieldUpdate.set(2, VectorValue.sparse(values^)))
        updates.append(
            FieldUpdate.set(
                3, VectorValue.sparse([SparseElement(1, Float32(i + 1))])
            )
        )
        var payload: List[DocumentField] = [
            DocumentField("keep", PayloadValue.boolean(i != 0))
        ]
        batch.append(PointMutation(ids[i], 1, updates^, Optional(payload^)))
    _ = collection.apply_point_batch(batch)
    var snapshot = collection.snapshot()
    var query = VectorValue.sparse(
        [SparseElement(1, 1), SparseElement(2, 1), SparseElement(3, 1)]
    )
    var result = snapshot.search_field_reported("terms", query, 10)
    assert_equal(result.reason, "field_sparse")
    assert_equal(result.stats.storage_name, "field-postings")
    var expected_ids: List[Int] = [-8, -3, 5, 10]
    var expected_scores: List[Float64] = [1, 0, 0, -1]
    for i in range(4):
        assert_equal(result.results[i].id, expected_ids[i])
        assert_equal(result.results[i].score, expected_scores[i])
    var expression = Optional(
        FilterExpression.condition(
            FilterCondition.equal("keep", PayloadValue.boolean(True))
        )
    )
    var filtered = snapshot.search_field("terms", query, 10, expression^)
    assert_equal(len(filtered), 3)
    assert_equal(filtered[0].id, -3)
    assert_equal(filtered[2].score, Float64(-1))
    var other = snapshot.search_field("other", query, 1)
    assert_equal(other[0].id, 0)
    assert_equal(other[0].score, Float64(5))
    var empty_query = VectorValue.sparse([])
    var empty = snapshot.search_field("terms", empty_query, 2)
    assert_equal(empty[0].id, -8)
    assert_equal(empty[0].score, Float64(0))
    var root = snapshot._acquire()
    assert_equal(root[].field_sparse[].get(2)[].build_count, 1)
    assert_equal(root[].field_sparse[].get(3)[].build_count, 1)
    var queries: List[FieldQuery] = [
        FieldQuery("terms", VectorValue.sparse([SparseElement(1, 1)])),
        FieldQuery("other", VectorValue.sparse([SparseElement(1, 1)])),
    ]
    var fused = snapshot.search_fields(queries, 4, fetch_k=4)
    var remove: List[PointMutation] = [
        PointMutation(-8, 3, [FieldUpdate.remove(2)])
    ]
    _ = collection.apply_point_batch(remove)
    assert_equal(collection.search_field("terms", query, 1)[0].id, -3)
    collection.flush()
    collection.close()
    assert_equal(snapshot.search_field("terms", query, 1)[0].id, -8)
    var fused_after = snapshot.search_fields(queries, 4, fetch_k=4)
    for i in range(len(fused)):
        assert_equal(fused_after[i].id, fused[i].id)
        assert_equal(fused_after[i].score, fused[i].score)
    snapshot.close()
    var reopened = PersistentCollection.open_with_fields(
        path, fields.copy(), maintenance_library_path=""
    )
    assert_equal(reopened.search_field("terms", query, 1)[0].id, -3)
    reopened.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def test_sparse_artifact_deadline_retry_and_concurrent_readers() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-sparse-control-"
        )
    )
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    fields.append(VectorFieldSpec(2, "terms", 1, 0, 0, 2, 0))
    var collection = PersistentCollection.open_with_fields(
        path, fields^, maintenance_library_path=""
    )
    var batch = List[PointMutation]()
    for i in range(64):
        batch.append(
            PointMutation(
                -i,
                1,
                [
                    FieldUpdate.set(
                        2,
                        VectorValue.sparse(
                            [SparseElement(i % 3, Float32(max(1, i)))]
                        ),
                    )
                ],
            )
        )
    _ = collection.apply_point_batch(batch)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var state = root[].field_sparse[].get(2)
    state[].delay_for_test = 0.1
    var token = CancellationToken()
    var expired = Optional(
        QueryControl(
            token, max_candidates=64, deadline_ns=perf_counter_ns() + 50_000_000
        )
    )
    var query = VectorValue.sparse([SparseElement(1, 2)])
    with assert_raises(contains="deadline"):
        _ = snapshot.search_field("terms", query, 3, control=expired)
    assert_equal(state[].status, ARTIFACT_FAILED)
    assert_true(not Bool(state[].ready))
    state[].delay_for_test = 0.01
    var failures = List[Int](length=8, fill=0)

    def run_query(index: Int) {imm snapshot, imm query, mut failures}:
        try:
            var results = snapshot.search_field("terms", query, 3)
            assert_equal(results[0].id, -61)
            assert_equal(results[0].score, Float64(122))
        except:
            failures[index] += 1

    parallelize(run_query, 8, 8)
    for failure in failures:
        assert_equal(failure, 0)
    assert_equal(state[].build_count, 1)
    assert_equal(state[].status, ARTIFACT_READY)
    var queries: List[FieldQuery] = [
        FieldQuery("terms", VectorValue.sparse([SparseElement(1, 1)])),
        FieldQuery("terms", VectorValue.sparse([])),
    ]
    var limited = Optional(QueryControl(token, max_candidates=127))
    with assert_raises(contains="resource limit"):
        _ = snapshot.search_fields(queries, 2, fetch_k=3, control=limited)
    collection.close()
    snapshot.close()
    Python.import_module("shutil").rmtree(path)
