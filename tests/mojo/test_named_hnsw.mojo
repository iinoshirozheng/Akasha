from akasha import CollectionConfig, PersistentCollection
from akasha.common.config import MetricKind, ScalarKind
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.query.filter_ast import FilterCondition, FilterExpression
from std.python import Python
from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from akasha.index.artifact_state import ARTIFACT_FAILED, ARTIFACT_READY
from akasha.query.control import CancellationToken, QueryControl
from max.algorithm import parallelize
from std.time import perf_counter_ns


def _fields() raises -> List[VectorFieldSpec]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    var image = CollectionConfig.defaults(4)
    image.ann_metric = MetricKind.dot()
    image.scalar_kind = ScalarKind.bf16()
    image.m = 4
    image.m0 = 8
    image.ef_construction = 64
    image.default_ef_search = 128
    image.max_ef_search = 256
    fields.append(VectorFieldSpec(2, "image", 0, 2, 0, 1, 4, Optional(image^)))
    var audio = CollectionConfig.defaults(2)
    audio.m = 4
    audio.m0 = 8
    audio.ef_construction = 64
    audio.default_ef_search = 128
    audio.max_ef_search = 256
    fields.append(VectorFieldSpec(3, "audio", 0, 4, 1, 1, 2, Optional(audio^)))
    return fields^


def _populate(mut collection: PersistentCollection) raises:
    var batch = List[PointMutation]()
    for row in range(96):
        var fields = List[FieldUpdate]()
        if row % 7 != 0:
            fields.append(
                FieldUpdate.set(
                    2,
                    VectorValue.dense[DType.float16](
                        [
                            Float16(row % 11),
                            Float16(row % 13),
                            Float16(row % 17),
                            Float16(1),
                        ]
                    ),
                )
            )
        fields.append(
            FieldUpdate.set(
                3, VectorValue.dense[DType.uint8]([UInt8(row), UInt8(row % 9)])
            )
        )
        var payload: List[DocumentField] = [
            DocumentField("group", PayloadValue.integer(Int64(row % 2)))
        ]
        batch.append(PointMutation(-row, 1, fields^, Optional(payload^)))
    _ = collection.apply_point_batch(batch)


def _predicate(enabled: Bool) raises -> Optional[FilterExpression]:
    if enabled:
        return Optional(
            FilterExpression.condition(
                FilterCondition.equal("group", PayloadValue.integer(1))
            )
        )
    return None


def test_named_graphs_use_own_identity_presence_filter_and_native_rerank() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(prefix="akasha-named-hnsw-")
    )
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _populate(collection)
    var snapshot = collection.snapshot()
    var sibling = collection.snapshot()
    var image = VectorValue.dense[DType.float16](
        [Float16(0.5), Float16(-0.25), Float16(1), Float16(2)]
    )
    var audio = VectorValue.dense[DType.uint8]([UInt8(31), UInt8(4)])
    for filtered in [False, True]:
        var expected = snapshot.search_field(
            "image", image, 7, _predicate(filtered)
        )
        var actual = snapshot.search_field(
            "image",
            image,
            7,
            _predicate(filtered),
            approximate=True,
            ef_search=128,
            rerank_k=128,
        )
        assert_equal(len(actual), len(expected))
        for i in range(len(expected)):
            assert_equal(actual[i].id, expected[i].id)
            assert_equal(actual[i].score, expected[i].score)
        var other = sibling.search_field(
            "audio",
            audio,
            7,
            _predicate(filtered),
            approximate=True,
            ef_search=128,
        )
        var other_exact = sibling.search_field(
            "audio", audio, 7, _predicate(filtered)
        )
        for i in range(len(other_exact)):
            assert_equal(other[i].id, other_exact[i].id)
            assert_equal(other[i].score, other_exact[i].score)
    var root = snapshot._acquire()
    assert_equal(root[].field_hnsw[].get(2)[].build_count, 1)
    assert_equal(root[].field_hnsw[].get(3)[].build_count, 1)
    assert_equal(root[].field_hnsw[].count(), 2)
    collection.flush()
    collection.close()
    assert_true(
        len(snapshot.search_field("image", image, 7, approximate=True)) == 7
    )
    snapshot.close()
    sibling.close()
    var reopened = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    var exact = reopened.search_field("audio", audio, 7)
    var after = reopened.search_field(
        "audio", audio, 7, approximate=True, ef_search=128
    )
    for i in range(len(exact)):
        assert_equal(after[i].id, exact[i].id)
        assert_equal(after[i].score, exact[i].score)
    reopened.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def test_build_failure_freshness_and_concurrent_first_queries() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-field-share-"
        )
    )
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _populate(collection)
    var snapshot = collection.snapshot()
    var query = VectorValue.dense[DType.uint8]([UInt8(31), UInt8(4)])
    var expected = snapshot.search_field("audio", query, 7)
    var root = snapshot._acquire()
    var state = root[].field_hnsw[].get(3)
    state[].fail_for_test = True
    with assert_raises(contains="derived index build failed"):
        _ = snapshot.search_field("audio", query, 7, approximate=True)
    assert_equal(state[].status, ARTIFACT_FAILED)
    assert_true(not Bool(state[].ready))
    state[].fail_for_test = False
    state[].delay_for_test = 0.05
    var failures = List[Int](length=8, fill=0)

    def run_query(
        index: Int,
    ) {imm snapshot, imm query, imm expected, mut failures}:
        for _ in range(4):
            try:
                var actual = snapshot.search_field(
                    "audio", query, 7, approximate=True
                )
                assert_equal(len(actual), len(expected))
                for row in range(len(expected)):
                    assert_equal(actual[row].id, expected[row].id)
                    assert_equal(actual[row].score, expected[row].score)
            except:
                failures[index] += 1

    parallelize(run_query, 8, 8)
    for failure in failures:
        assert_equal(failure, 0)
    assert_equal(state[].build_count, 1)
    assert_equal(state[].failure_count, 1)
    var updates: List[FieldUpdate] = [
        FieldUpdate.set(
            3, VectorValue.dense[DType.uint8]([UInt8(31), UInt8(4)])
        )
    ]
    var batch: List[PointMutation] = [PointMutation(-999, 1, updates^)]
    _ = collection.apply_point_batch(batch)
    var fresh = collection.snapshot()
    var fresh_root = fresh._acquire()
    assert_equal(fresh_root[].field_hnsw[].count(), 0)
    assert_equal(
        fresh.search_field("audio", query, 1, approximate=True)[0].id, -999
    )
    collection.close()
    var old = snapshot.search_field("audio", query, 7, approximate=True)
    assert_equal(old[0].id, expected[0].id)
    snapshot.close()
    fresh.close()
    _ = root^
    _ = fresh_root^
    assert_equal(collection._pins[].active_count(), 0)
    Python.import_module("shutil").rmtree(path)


def test_named_control_cancelled_build_never_publishes() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-field-cancel-"
        )
    )
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _populate(collection)
    var snapshot = collection.snapshot()
    var query = VectorValue.dense[DType.uint8]([UInt8(31), UInt8(4)])
    var root = snapshot._acquire()
    var state = root[].field_hnsw[].get(3)
    state[].delay_for_test = 0.1
    var token = CancellationToken()
    var deadline = Optional(
        QueryControl(
            token,
            max_candidates=128,
            deadline_ns=perf_counter_ns() + 50_000_000,
        )
    )
    with assert_raises(contains="query deadline exceeded"):
        _ = snapshot.search_field(
            "audio", query, 7, approximate=True, control=deadline
        )
    assert_equal(state[].status, ARTIFACT_FAILED)
    assert_true(not Bool(state[].ready))
    assert_equal(state[].build_count, 0)
    state[].delay_for_test = 0.0
    _ = snapshot.search_field("audio", query, 7, approximate=True)
    assert_equal(state[].build_count, 1)
    token.cancel()
    var cancelled = Optional(QueryControl(token, max_candidates=128))
    for approximate in [False, True]:
        with assert_raises(contains="query cancelled"):
            _ = snapshot.search_field(
                "audio", query, 7, approximate=approximate, control=cancelled
            )
    assert_equal(state[].status, ARTIFACT_READY)
    var live = CancellationToken()
    var limited = Optional(QueryControl(live, max_candidates=95))
    for approximate in [False, True]:
        with assert_raises(contains="resource limit"):
            _ = snapshot.search_field(
                "audio", query, 7, approximate=approximate, control=limited
            )
    collection.close()
    snapshot.close()
    Python.import_module("shutil").rmtree(path)
