from akasha import CollectionConfig, IvfOptions, PersistentCollection
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.index.artifact_state import ARTIFACT_FAILED, ARTIFACT_READY
from akasha.query.control import CancellationToken, QueryControl
from akasha.query.field_ivf import search_generation_field_ivf
from akasha.query.filter_ast import FilterCondition, FilterExpression
from max.algorithm import parallelize
from std.python import Python
from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from std.time import perf_counter_ns


def _fields(scalar: UInt8) raises -> List[VectorFieldSpec]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(3))
    for metric in range(3):
        fields.append(
            VectorFieldSpec(
                2 + metric, String("v", metric), 0, scalar, UInt8(metric), 0, 3
            )
        )
    return fields^


def _populate[dtype: DType](mut collection: PersistentCollection) raises:
    var batch = List[PointMutation]()
    for row in range(48):
        var updates = List[FieldUpdate]()
        if row % 7 != 0:
            for metric in range(3):
                updates.append(
                    FieldUpdate.set(
                        2 + metric,
                        VectorValue.dense[dtype](
                            [
                                Scalar[dtype](row // 4 + 1),
                                Scalar[dtype](row % 3),
                                Scalar[dtype](1),
                            ]
                        ),
                    )
                )
        var payload: List[DocumentField] = [
            DocumentField("keep", PayloadValue.boolean(row % 2 == 0))
        ]
        batch.append(PointMutation(row - 30, 1, updates^, Optional(payload^)))
    _ = collection.apply_point_batch(batch)


def _filter(enabled: Bool) raises -> Optional[FilterExpression]:
    if enabled:
        return Optional(
            FilterExpression.condition(
                FilterCondition.equal("keep", PayloadValue.boolean(True))
            )
        )
    return None


def _native_oracle[dtype: DType, scalar: UInt8]() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(prefix="akasha-ivf-native-")
    )
    var fields = _fields(scalar)
    var collection = PersistentCollection.open_with_fields(
        path, fields.copy(), maintenance_library_path=""
    )
    _populate[dtype](collection)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var query = VectorValue.dense[dtype](
        [Scalar[dtype](5), Scalar[dtype](1), Scalar[dtype](1)]
    )
    for metric in range(3):
        for filtered in [False, True]:
            var expected = snapshot.search_field(
                String("v", metric), query, 8, _filter(filtered)
            )
            var actual = snapshot.search_field_reported(
                String("v", metric),
                query,
                8,
                _filter(filtered),
                ivf=Optional(IvfOptions(4, 4, 3)),
            )
            assert_equal(actual.reason, "field_ivf")
            assert_equal(actual.stats.storage_name, "field-ivf")
            assert_equal(actual.stats.ivf_partitions, 4)
            assert_equal(actual.stats.ivf_probed_partitions, 4)
            assert_equal(len(actual.results), len(expected))
            for i in range(len(expected)):
                assert_equal(actual.results[i].id, expected[i].id)
                assert_equal(actual.results[i].score, expected[i].score)
        assert_equal(root[].field_ivf[].get(2 + metric, 4, 3)[].build_count, 1)
    var partial = search_generation_field_ivf(
        root[], fields[3], query, 48, None, 4, 1, 3
    )
    assert_true(partial.stats.base_visited < 41)
    assert_equal(partial.stats.ivf_probed_partitions, 1)
    assert_equal(partial.stats.reranked_candidates, partial.stats.base_visited)
    _ = search_generation_field_ivf(root[], fields[3], query, 8, None, 2, 2, 3)
    _ = search_generation_field_ivf(root[], fields[3], query, 8, None, 4, 4, 2)
    assert_equal(root[].field_ivf[].count(), 5)
    collection.close()
    _ = search_generation_field_ivf(root[], fields[3], query, 8, None, 4, 4, 3)
    snapshot.close()
    _ = root^
    Python.import_module("shutil").rmtree(path)


def test_ivf_all_native_dense_types_metrics_filters_and_probe_counts() raises:
    _native_oracle[DType.float32, 0]()
    _native_oracle[DType.bfloat16, 1]()
    _native_oracle[DType.float16, 2]()
    _native_oracle[DType.int8, 3]()
    _native_oracle[DType.uint8, 4]()


def test_ivf_failed_deadline_build_retry_and_concurrent_publication() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-ivf-control-"
        )
    )
    var fields = _fields(0)
    var collection = PersistentCollection.open_with_fields(
        path, fields.copy(), maintenance_library_path=""
    )
    _populate[DType.float32](collection)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var query = VectorValue.dense[DType.float32]([5, 1, 1])
    var expected = snapshot.search_field("v1", query, 8)
    var state = root[].field_ivf[].get(3, 4, 3)
    state[].delay_for_test = 0.05
    var token = CancellationToken()
    var control = Optional(
        QueryControl(
            token, max_candidates=48, deadline_ns=perf_counter_ns() + 1_000_000
        )
    )
    with assert_raises(contains="deadline"):
        _ = search_generation_field_ivf(
            root[], fields[3], query, 8, None, 4, 4, 3, control
        )
    assert_equal(state[].status, ARTIFACT_FAILED)
    assert_true(not Bool(state[].ready))
    var failures = List[Int](length=8, fill=0)

    def run_query(
        index: Int,
    ) {imm root, imm fields, imm query, imm expected, mut failures}:
        try:
            var actual = search_generation_field_ivf(
                root[], fields[3], query, 8, None, 4, 4, 3
            )
            assert_equal(len(actual.results), len(expected))
            for i in range(len(expected)):
                assert_equal(actual.results[i].id, expected[i].id)
                assert_equal(actual.results[i].score, expected[i].score)
        except:
            failures[index] += 1

    parallelize(run_query, 8, 8)
    for failure in failures:
        assert_equal(failure, 0)
    assert_equal(state[].status, ARTIFACT_READY)
    assert_equal(state[].build_count, 1)
    assert_equal(state[].failure_count, 1)
    var updates: List[PointMutation] = [
        PointMutation(
            -99,
            1,
            [FieldUpdate.set(3, VectorValue.dense[DType.float32]([5, 1, 1]))],
        )
    ]
    _ = collection.apply_point_batch(updates)
    var fresh = collection.snapshot()
    var fresh_root = fresh._acquire()
    assert_equal(fresh_root[].field_ivf[].count(), 0)
    var new_result = search_generation_field_ivf(
        fresh_root[], fields[3], query, 1, None, 4, 4, 3
    )
    assert_equal(new_result.results[0].id, -99)
    var old_result = search_generation_field_ivf(
        root[], fields[3], query, 8, None, 4, 4, 3
    )
    assert_equal(old_result.results[0].id, expected[0].id)
    collection.close()
    snapshot.close()
    fresh.close()
    _ = root^
    _ = fresh_root^
    Python.import_module("shutil").rmtree(path)


def test_ivf_rejects_invalid_options_before_retaining_empty_artifacts() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(prefix="akasha-ivf-empty-")
    )
    var fields = _fields(0)
    var collection = PersistentCollection.open_with_fields(
        path, fields.copy(), maintenance_library_path=""
    )
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var query = VectorValue.dense[DType.float32]([5, 1, 1])
    for lists in [0, 257]:
        with assert_raises():
            _ = search_generation_field_ivf(
                root[], fields[3], query, 1, None, lists, 1, 3
            )
    for probes in [0, 5]:
        with assert_raises():
            _ = search_generation_field_ivf(
                root[], fields[3], query, 1, None, 4, probes, 3
            )
    with assert_raises():
        _ = search_generation_field_ivf(
            root[], fields[3], query, 1, None, 4, 1, 0
        )
    with assert_raises():
        _ = search_generation_field_ivf(
            root[], fields[3], query, 0, None, 4, 1, 3
        )
    var empty = search_generation_field_ivf(
        root[], fields[3], query, 1, None, 4, 1, 3
    )
    assert_equal(len(empty.results), 0)
    assert_equal(root[].field_ivf[].count(), 0)
    collection.close()
    snapshot.close()
    _ = root^
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
