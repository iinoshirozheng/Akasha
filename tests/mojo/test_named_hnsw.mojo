from akasha import CollectionConfig, PersistentCollection
from akasha.api.snapshot import ReadSnapshot
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
    assert_equal(root[].run(0).field_hnsw[].get(2)[].build_count, 1)
    assert_equal(root[].run(0).field_hnsw[].get(3)[].build_count, 1)
    assert_equal(root[].run(0).field_hnsw[].count(), 2)
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
    var state = root[].run(0).field_hnsw[].get(3)
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
    assert_true(fresh_root[].run(0).field_hnsw[].get(3) is state)
    var head_state = fresh_root[].run(1).field_hnsw[].get(3)
    head_state[].fail_for_test = True
    with assert_raises(contains="derived index build failed"):
        _ = fresh.search_field("audio", query, 1, approximate=True)
    assert_equal(state[].status, ARTIFACT_READY)
    assert_equal(state[].build_count, 1)
    assert_equal(head_state[].status, ARTIFACT_FAILED)
    assert_true(not Bool(head_state[].ready))
    head_state[].fail_for_test = False
    assert_equal(
        fresh.search_field("audio", query, 1, approximate=True)[0].id, -999
    )
    assert_equal(state[].build_count, 1)
    assert_equal(fresh_root[].run(1).field_hnsw[].get(3)[].build_count, 1)
    assert_equal(
        len(fresh_root[].run(1).field_hnsw[].get(3)[].ready.value()[].rows), 1
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


def _check_layered_audio(snapshot: ReadSnapshot, query: VectorValue) raises:
    for filtered in [False, True]:
        var expected = snapshot.search_field("audio", query, 7, _predicate(filtered))
        var actual = snapshot.search_field_reported(
            "audio", query, 7, _predicate(filtered),
            approximate=True, ef_search=128, rerank_k=7,
        )
        assert_equal(actual.reason, "field_ann")
        assert_equal(actual.stats.reranked_candidates, 7)
        assert_equal(actual.stats.retained_candidates, len(expected))
        assert_equal(len(actual.results), len(expected))
        for row in range(len(expected)):
            assert_equal(actual.results[row].id, expected[row].id)
            assert_equal(actual.results[row].score, expected[row].score)


def test_run_graphs_shadow_before_global_budget_and_survive_merge() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-field-runs-"))
    var collection = PersistentCollection.open_with_fields(
        path, _fields(), maintenance_library_path=""
    )
    _populate(collection)
    var original = collection.snapshot()
    var query = VectorValue.dense[DType.uint8]([UInt8(31), UInt8(4)])
    _check_layered_audio(original, query)
    var original_root = original._acquire()
    var base_state = original_root[].run(0).field_hnsw[].get(3)
    # Nearest rows become excluded, missing or deleted; the old graph remains
    # searchable only through this root's visibility and payload admission.
    var changes = List[PointMutation]()
    var payload: List[DocumentField] = [DocumentField("group", PayloadValue.integer(0))]
    changes.append(PointMutation(-31, 3, [], Optional(payload^)))
    changes.append(PointMutation(-30, 3, [FieldUpdate.remove(3)]))
    changes.append(PointMutation.delete(-32))
    changes.append(PointMutation(-29, 3, [FieldUpdate.set(
        3, VectorValue.dense[DType.uint8]([UInt8(255), UInt8(255)])
    )]))
    # Reach the existing head bound without adding any field candidates.
    for id in range(1020):
        changes.append(PointMutation(1000 + id, 1, []))
    _ = collection.apply_point_batch(changes)
    var sealed = collection.snapshot()
    var sealed_root = sealed._acquire()
    assert_equal(sealed_root[].layer_count(), 2)
    assert_true(sealed_root[].run(0).field_hnsw[].get(3) is base_state)
    _check_layered_audio(sealed, query)
    assert_equal(base_state[].build_count, 1)
    var sealed_state = sealed_root[].run(1).field_hnsw[].get(3)
    assert_equal(sealed_state[].build_count, 1)
    assert_equal(len(sealed_state[].ready.value()[].rows), 2)
    var reinsertion: List[PointMutation] = [PointMutation(
        -32, 1, [FieldUpdate.set(3, VectorValue.dense[DType.uint8]([UInt8(31), UInt8(4)]))],
        Optional[List[DocumentField]]([DocumentField("group", PayloadValue.integer(1))])
    )]
    _ = collection.apply_point_batch(reinsertion)
    var latest = collection.snapshot()
    var latest_root = latest._acquire()
    assert_equal(latest_root[].layer_count(), 3)
    assert_true(latest_root[].run(1).field_hnsw[].get(3) is sealed_state)
    _check_layered_audio(latest, query)
    assert_equal(latest.search_field("audio", query, 1, approximate=True)[0].id, -32)
    # Exercise the same captured merge publication used by maintenance. The
    # frozen head survives, while the merged base gets a new artifact owner.
    collection._read_generations[].merge_sealed_runs()
    var merged = collection.snapshot()
    var merged_root = merged._acquire()
    assert_equal(merged_root[].layer_count(), 2)
    assert_true(not (merged_root[].run(0).field_hnsw[].get(3) is base_state))
    assert_true(merged_root[].layers[1].run is latest_root[].layers[2].run)
    _check_layered_audio(merged, query)
    collection.close()
    _check_layered_audio(original, query)
    _check_layered_audio(sealed, query)
    _check_layered_audio(latest, query)
    _check_layered_audio(merged, query)
    assert_equal(base_state[].build_count, 1)
    assert_equal(sealed_state[].build_count, 1)
    original.close()
    sealed.close()
    latest.close()
    merged.close()
    _ = original_root^
    _ = sealed_root^
    _ = latest_root^
    _ = merged_root^
    assert_equal(collection._pins[].active_count(), 0)
    Python.import_module("shutil").rmtree(path)


def test_run_graph_rejects_changed_identity_without_losing_ready_artifact() raises:
    from akasha.query.field_ann import _field_graph

    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-field-identity-"))
    var collection = PersistentCollection.open_with_fields(path, _fields(), maintenance_library_path="")
    _populate(collection)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var fields = _fields()
    var graph = _field_graph(root[].run(0), fields[3], None)
    fields[3].hnsw.value().ef_construction += 1
    with assert_raises(contains="field graph identity"):
        _ = _field_graph(root[].run(0), fields[3], None)
    fields[3].hnsw.value().ef_construction -= 1
    fields[3].scalar = 3
    with assert_raises(contains="field graph identity"):
        _ = _field_graph(root[].run(0), fields[3], None)
    fields[3].scalar = 4
    assert_true(_field_graph(root[].run(0), fields[3], None) is graph)
    assert_equal(root[].run(0).field_hnsw[].get(3)[].build_count, 1)
    collection.close()
    snapshot.close()
    Python.import_module("shutil").rmtree(path)


def test_named_candidate_budget_is_bounded_by_visible_population() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(prefix="akasha-field-budget-")
    )
    var fields = _fields()
    var maximum = Int(UInt32.MAX)
    fields[3].hnsw.value().max_ef_search = maximum
    var collection = PersistentCollection.open_with_fields(
        path, fields^, maintenance_library_path=""
    )
    var query = VectorValue.dense[DType.uint8]([UInt8(31), UInt8(4)])
    var empty = collection.snapshot()
    var result = empty.search_field_reported(
        "audio", query, 7, approximate=True,
        ef_search=maximum, rerank_k=maximum,
    )
    assert_equal(result.reason, "field_empty")
    assert_equal(len(result.results), 0)
    _populate(collection)
    var snapshot = collection.snapshot()
    var budgets: List[Tuple[Int, Int]] = [
        (maximum, maximum), (128, maximum), (maximum, 0)
    ]
    for filtered in [False, True]:
        var expected = snapshot.search_field(
            "audio", query, 7, _predicate(filtered)
        )
        for limits in budgets:
            var actual = snapshot.search_field_reported(
                "audio", query, 7, _predicate(filtered), approximate=True,
                ef_search=limits[0], rerank_k=limits[1],
            )
            assert_equal(len(actual.results), len(expected))
            assert_equal(actual.stats.reranked_candidates, 48 if filtered else 96)
            for row in range(len(expected)):
                assert_equal(actual.results[row].id, expected[row].id)
                assert_equal(actual.results[row].score, expected[row].score)
    empty.close()
    snapshot.close()
    collection.close()
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
    var state = root[].run(0).field_hnsw[].get(3)
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
