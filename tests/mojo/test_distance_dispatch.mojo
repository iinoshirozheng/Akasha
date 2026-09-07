from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.dispatch import (
    DISTANCE_DISPATCH_HOT_LOOP,
    DISTANCE_DISPATCH_PUBLIC_BOUNDARY,
    DISTANCE_DOT_F32,
    DISTANCE_L2_F32,
    DistanceBackend,
    DistanceDispatchCounters,
    portable_simd_width,
    record_distance_dispatch,
    select_distance_backend,
)
from akasha.compute.metric import MetricDispatcher
from akasha.compute.gpu.flat_scan import (
    _candidate_execution_stats,
    _execution_stats,
    execute_device_batch,
)
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.index.hnsw import HnswIndex
from akasha.index.bitmap import Bitmap
from akasha.index.flat import SearchResult
from akasha.index.hnsw_core import (
    HnswEligibility,
    HnswIdOrdinalLookup,
    HnswSearchAdmission,
)
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.index.hnsw_view import HnswGraphView
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import (
    encode_hnsw_snapshot,
    open_hnsw_snapshot_view,
)
from akasha.storage.memtable import MemTable
from akasha.query.batch_executor import (
    BATCH_COSINE_METRIC,
    BATCH_DOT_METRIC,
    BATCH_L2_METRIC,
    execute_exact_batch_reported,
    execute_scalar_exact_reported,
)
from akasha.query.parallel_scan import execute_parallel_scan_reported
from std.collections import Dict
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def _config(metric: MetricKind, scalar: ScalarKind) -> CollectionConfig:
    var config = CollectionConfig.defaults(4)
    config.ann_metric = metric.copy()
    config.scalar_kind = scalar.copy()
    return config^


def _assert_selected(metric: MetricKind, scalar: ScalarKind) raises:
    var counters = DistanceDispatchCounters()
    var backend = select_distance_backend(_config(metric, scalar), counters)
    assert_equal(
        backend.backend_name(),
        String("portable-simd-", portable_simd_width()),
    )
    assert_equal(backend.metric_name(), metric.name())
    assert_equal(backend.scalar_name(), scalar.name())
    assert_equal(counters.selection_count(), 1)
    assert_equal(counters.hot_loop_selection_count(), 0)


def test_dispatch_counters_measure_real_calls_instead_of_constants() raises:
    var counters = DistanceDispatchCounters()
    _ = select_distance_backend(
        _config(MetricKind.dot(), ScalarKind.f32()), counters
    )
    _ = select_distance_backend(
        _config(MetricKind.cosine(), ScalarKind.f16()), counters
    )
    record_distance_dispatch(counters, DISTANCE_DISPATCH_PUBLIC_BOUNDARY)
    record_distance_dispatch(counters, DISTANCE_DISPATCH_PUBLIC_BOUNDARY)
    assert_equal(counters.selection_count(), 2)
    assert_equal(counters.public_boundary_switch_count(), 2)
    assert_equal(counters.hot_loop_selection_count(), 0)
    record_distance_dispatch(counters, DISTANCE_DISPATCH_HOT_LOOP)
    assert_equal(counters.hot_loop_selection_count(), 1)


def test_forged_backend_tag_and_mismatched_injection_are_rejected() raises:
    var l2_config = _config(MetricKind.l2(), ScalarKind.f32())
    var l2_dispatcher = MetricDispatcher(
        MetricKind.l2(), ScalarKind.f32(), l2_config.dimension
    )
    with assert_raises():
        _ = DistanceBackend(l2_dispatcher, DISTANCE_DOT_F32)
    with assert_raises():
        _ = DistanceBackend(l2_dispatcher, 999)

    var dot_config = _config(MetricKind.dot(), ScalarKind.f32())
    var counters = DistanceDispatchCounters()
    var dot_backend = select_distance_backend(dot_config, counters)
    with assert_raises():
        _ = HnswIndex(l2_config, dot_backend)
    with assert_raises():
        _ = HnswGraphView(l2_config, dot_backend)
    with assert_raises():
        _ = SegmentedHnsw(l2_config, dot_backend, DistanceDispatchCounters())
    var owned = HnswIndex(l2_config)
    var owned_slots = owned.point_count()
    var owned_switches = owned.distance_backend_public_switch_count()
    var owned_distances = owned.last_search_distance_evaluations()
    with assert_raises():
        owned._bind_distance_backend(dot_backend)
    assert_equal(owned.point_count(), owned_slots)
    assert_equal(owned.distance_backend_public_switch_count(), owned_switches)
    assert_equal(owned.last_search_distance_evaluations(), owned_distances)
    var view = HnswGraphView(l2_config)
    var view_switches = view.distance_backend_public_switch_count()
    with assert_raises():
        view._bind_distance_backend(dot_backend)
    assert_equal(view.distance_backend_public_switch_count(), view_switches)


def test_specialized_graph_entrypoints_do_not_record_runtime_dispatch() raises:
    """Comptime-tagged storage, core, and view entries bypass the recorder."""
    var config = _index_config(ScalarKind.f32())
    config.ann_metric = MetricKind.l2()
    var owned = _index(config)
    var query = _vector(19)
    var prepared = owned.distance_backend.prepare_query(query)
    var owned_public = owned.distance_backend_public_switch_count()
    _ = owned.graph._distance_to_slot_backend[DISTANCE_L2_F32](
        owned.metric, prepared, UInt32(0)
    )
    _ = owned._search_bound_backend[backend_tag=DISTANCE_L2_F32](
        query, 4, 8, HnswSearchAdmission()
    )
    assert_equal(owned.distance_backend_public_switch_count(), owned_public)
    assert_equal(owned.distance_backend_hot_loop_selection_count(), 0)

    var path = String("/tmp/akasha-task27-specialized-entry.bin")
    remove_file_if_exists(path)
    write_file_sync(path, encode_hnsw_snapshot(owned, UInt64(27)))
    var mapped = open_hnsw_snapshot_view(path, config, UInt64(27))
    var mapped_dispatcher = mapped.metric()
    var mapped_prepared = mapped_dispatcher.prepare_query(query)
    var mapped_public = mapped.distance_backend_public_switch_count()
    _ = mapped._distance_to_slot_backend[DISTANCE_L2_F32](
        mapped_dispatcher, mapped_prepared, UInt32(0)
    )
    _ = mapped._search_backend[DISTANCE_L2_F32](query, 4, 8)
    assert_equal(mapped.distance_backend_public_switch_count(), mapped_public)
    assert_equal(mapped.distance_backend_hot_loop_selection_count(), 0)
    mapped.close()
    remove_file_if_exists(path)


def _assert_view_dispatch_state_unchanged(
    view: HnswGraphView,
    selection_count: Int,
    public_switch_count: Int,
    hot_loop_count: Int,
    expected_stats: HnswSearchStats,
    query_preparations: Int,
    upper_descents: Int,
) raises:
    assert_equal(view.distance_backend_selection_count(), selection_count)
    assert_equal(
        view.distance_backend_public_switch_count(), public_switch_count
    )
    assert_equal(
        view.distance_backend_hot_loop_selection_count(), hot_loop_count
    )
    var actual = view.last_search_stats()
    assert_equal(actual.requested_ef, expected_stats.requested_ef)
    assert_equal(actual.effective_ef, expected_stats.effective_ef)
    assert_equal(actual.widening_rounds, expected_stats.widening_rounds)
    assert_equal(actual.upper_visited, expected_stats.upper_visited)
    assert_equal(actual.base_visited, expected_stats.base_visited)
    assert_equal(
        actual.distance_evaluations, expected_stats.distance_evaluations
    )
    assert_equal(actual.retained_candidates, expected_stats.retained_candidates)
    assert_equal(actual.reranked_candidates, expected_stats.reranked_candidates)
    assert_equal(actual.filtered_rejections, expected_stats.filtered_rejections)
    assert_equal(actual.inactive_rejections, expected_stats.inactive_rejections)
    assert_equal(actual.base_candidates, expected_stats.base_candidates)
    assert_equal(actual.delta_candidates, expected_stats.delta_candidates)
    assert_equal(actual.backend_name, expected_stats.backend_name)
    assert_equal(actual.metric_name, expected_stats.metric_name)
    assert_equal(actual.scalar_name, expected_stats.scalar_name)
    assert_equal(actual.storage_name, expected_stats.storage_name)
    assert_equal(actual.fallback_reason, expected_stats.fallback_reason)
    assert_equal(view.last_search_query_preparations(), query_preparations)
    assert_equal(view.last_search_upper_descents(), upper_descents)


def test_mapped_view_rejects_forged_backend_before_every_dispatch() raises:
    var config = _index_config(ScalarKind.f32())
    config.ann_metric = MetricKind.l2()
    var owned = _index(config)
    var path = String("/tmp/akasha-task27-forged-view.bin")
    remove_file_if_exists(path)
    write_file_sync(path, encode_hnsw_snapshot(owned, UInt64(27)))
    var view = open_hnsw_snapshot_view(path, config, UInt64(27))
    var query = _vector(19)
    var dispatcher = view.metric()
    var prepared = dispatcher.prepare_query(query)

    # All three dispatch boundaries accept the correctly bound backend.
    var correct_switches = view.distance_backend_public_switch_count()
    _ = view.search(query, 4, ef_search=8)
    _ = view._search_admitted_prepared_candidates_with_widening(
        prepared, 4, 4, 8, view.live_point_count(), HnswSearchAdmission()
    )
    _ = view._search_admitted_with_actual_widening(
        query,
        4,
        4,
        8,
        view.live_point_count(),
        HnswSearchAdmission(),
        True,
        False,
    )
    assert_equal(
        view.distance_backend_public_switch_count(), correct_switches + 3
    )

    var selections = view.distance_backend_selection_count()
    var switches = view.distance_backend_public_switch_count()
    var hot_loop = view.distance_backend_hot_loop_selection_count()
    var stats = view.last_search_stats()
    var query_preparations = view.last_search_query_preparations()
    var upper_descents = view.last_search_upper_descents()
    view._distance_backend._tag = DISTANCE_DOT_F32

    with assert_raises():
        _ = view.search(query, 4, ef_search=8)
    _assert_view_dispatch_state_unchanged(
        view,
        selections,
        switches,
        hot_loop,
        stats,
        query_preparations,
        upper_descents,
    )
    with assert_raises():
        _ = view._search_admitted_prepared_candidates_with_widening(
            prepared, 4, 4, 8, view.live_point_count(), HnswSearchAdmission()
        )
    _assert_view_dispatch_state_unchanged(
        view,
        selections,
        switches,
        hot_loop,
        stats,
        query_preparations,
        upper_descents,
    )
    with assert_raises():
        _ = view._search_admitted_with_actual_widening(
            query,
            4,
            4,
            8,
            view.live_point_count(),
            HnswSearchAdmission(),
            True,
            False,
        )
    _assert_view_dispatch_state_unchanged(
        view,
        selections,
        switches,
        hot_loop,
        stats,
        query_preparations,
        upper_descents,
    )
    view.close()
    remove_file_if_exists(path)


def test_selects_every_enabled_metric_scalar_pair_once() raises:
    for metric in [MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()]:
        _assert_selected(metric, ScalarKind.f32())
        _assert_selected(metric, ScalarKind.bf16())
        _assert_selected(metric, ScalarKind.f16())
        if metric != MetricKind.l2():
            _assert_selected(metric, ScalarKind.i8())


def test_backend_matches_scalar_reference_for_prepared_values() raises:
    var lhs: List[Float32] = [1.25, -2.0, 0.5, 3.0]
    var rhs: List[Float32] = [-0.5, 4.0, 2.0, 1.5]
    for metric in [MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()]:
        for scalar in [ScalarKind.f32(), ScalarKind.bf16(), ScalarKind.f16()]:
            var counters = DistanceDispatchCounters()
            var backend = select_distance_backend(
                _config(metric, scalar), counters
            )
            var prepared_lhs = backend.prepare_query(lhs)
            var prepared_rhs = backend.prepare_graph_vector(rhs)
            var actual = backend.canonical_prepared(prepared_lhs, prepared_rhs)
            var expected = backend.scalar_reference_prepared(
                prepared_lhs, prepared_rhs
            )
            var difference = actual - expected
            if difference < 0.0:
                difference = -difference
            assert_true(difference <= 1.0e-5)

    for metric in [MetricKind.dot(), MetricKind.cosine()]:
        var counters = DistanceDispatchCounters()
        var backend = select_distance_backend(
            _config(metric, ScalarKind.i8()), counters
        )
        var prepared_lhs = backend.prepare_query(lhs)
        var prepared_rhs = backend.prepare_graph_vector(rhs)
        assert_equal(
            backend.canonical_prepared(prepared_lhs, prepared_rhs),
            backend.scalar_reference_prepared(prepared_lhs, prepared_rhs),
        )


def _index_config(scalar: ScalarKind) -> CollectionConfig:
    var config = _config(MetricKind.dot(), scalar)
    config.m = 4
    config.m0 = 8
    config.ef_construction = 16
    config.default_ef_search = 8
    config.max_ef_search = 64
    config.max_level = 4
    return config^


def _vector(id: Int) -> List[Float32]:
    return [
        Float32(id),
        Float32(id % 3) + 0.25,
        Float32(id % 5) - 0.5,
        Float32(id % 7) + 1.0,
    ]


def _index(config: CollectionConfig) raises -> HnswIndex:
    var index = HnswIndex(config)
    for id in range(1, 13):
        index.add(id, _vector(id))
    return index^


def _lookup(table: MemTable) raises -> HnswIdOrdinalLookup:
    var ordinals = Dict[Int, Int]()
    for ordinal in range(table.slot_count()):
        ordinals[table.id_at(ordinal)] = ordinal
    return HnswIdOrdinalLookup(ordinals^, table.slot_count())


def test_owned_index_selects_once_and_never_reselects_per_distance() raises:
    var index = _index(_index_config(ScalarKind.f16()))
    assert_equal(index.distance_backend_selection_count(), 1)
    assert_equal(index.distance_backend_hot_loop_selection_count(), 0)
    var before = index.distance_backend_public_switch_count()
    assert_true(before > 1)
    _ = index.search(_vector(19), 4, ef_search=8)
    assert_equal(index.distance_backend_selection_count(), 1)
    assert_equal(index.distance_backend_public_switch_count(), before + 1)
    assert_equal(index.distance_backend_hot_loop_selection_count(), 0)
    assert_true(index.last_search_distance_evaluations() > 0)
    assert_equal(
        index.last_search_stats.backend_name,
        String("portable-simd-", portable_simd_width()),
    )


def test_mapped_compact_index_preserves_one_selection_and_backend_stats() raises:
    var config = _index_config(ScalarKind.bf16())
    var index = _index(config.copy())
    var path = String("/tmp/akasha-task27-distance-dispatch.bin")
    remove_file_if_exists(path)
    write_file_sync(path, encode_hnsw_snapshot(index, UInt64(27)))
    var view = open_hnsw_snapshot_view(path, config, UInt64(27))
    assert_equal(view.distance_backend_selection_count(), 1)
    var before = view.distance_backend_public_switch_count()
    _ = view.search(_vector(21), 4, ef_search=8)
    assert_equal(view.distance_backend_selection_count(), 1)
    assert_equal(view.distance_backend_public_switch_count(), before + 1)
    assert_equal(view.distance_backend_hot_loop_selection_count(), 0)
    assert_equal(
        view.last_search_stats().backend_name,
        String("portable-simd-", portable_simd_width()),
    )
    view.close()
    remove_file_if_exists(path)


def test_segmented_compact_path_reports_same_backend_without_redispatch() raises:
    var config = _index_config(ScalarKind.i8())
    var table = MemTable(config.dimension)
    var segmented = SegmentedHnsw(config.copy())
    for id in range(1, 13):
        var values = _vector(id)
        table.apply_upsert(id, UInt64(id), values.copy())
        segmented.upsert(id, values^)
    var lookup = _lookup(table)
    assert_equal(segmented.distance_backend_selection_count(), 1)
    var before = segmented.distance_backend_public_switch_count()
    _ = segmented.search(_vector(23), 4, 8, table, lookup)
    assert_equal(segmented.distance_backend_selection_count(), 1)
    assert_equal(segmented.distance_backend_public_switch_count(), before + 1)
    assert_equal(segmented.distance_backend_hot_loop_selection_count(), 0)
    var stats = segmented.last_search_stats()
    assert_equal(
        stats.backend_name,
        String("portable-simd-", portable_simd_width()),
    )
    assert_equal(stats.metric_name, "dot")
    assert_equal(stats.scalar_name, "i8")
    assert_equal(stats.fallback_reason, "")
    assert_true(stats.distance_evaluations > 0)


def _assert_close(actual: Float32, expected: Float32) raises:
    var difference = actual - expected
    if difference < 0.0:
        difference = -difference
    assert_true(difference <= 1.0e-4)


def _assert_graph_kernel_pair(metric: MetricKind, scalar: ScalarKind) raises:
    var config = _index_config(scalar)
    config.ann_metric = metric.copy()
    var owned = HnswIndex(config)
    var table = MemTable(config.dimension)
    for id in range(1, 9):
        var values = _vector(id)
        table.apply_upsert(id, UInt64(id), values.copy())
        owned.add(id, values^)
    assert_equal(owned.distance_backend_selection_count(), 1)
    var query = _vector(19)
    var owned_before = owned.distance_backend_public_switch_count()
    var owned_results = owned.search(query, 8, ef_search=8)
    assert_equal(owned.distance_backend_public_switch_count(), owned_before + 1)
    assert_equal(owned.distance_backend_hot_loop_selection_count(), 0)
    assert_true(owned.last_search_distance_evaluations() > 1)
    var prepared_query = owned.distance_backend.prepare_query(query)
    for result in owned_results:
        var prepared_vector = owned.distance_backend.prepare_graph_vector(
            _vector(result.id)
        )
        _assert_close(
            result.score,
            owned.metric.public_score(
                owned.distance_backend.canonical_prepared(
                    prepared_query, prepared_vector
                )
            ),
        )

    var ordinals = Dict[Int, Int]()
    var bitmap = Bitmap(8)
    for ordinal in range(8):
        ordinals[ordinal + 1] = ordinal
        bitmap.set(ordinal)
    var eligibility = HnswEligibility(
        bitmap^, HnswIdOrdinalLookup(ordinals^, 8)
    )
    var widen_before = owned.distance_backend_public_switch_count()
    _ = owned.search_allowed_with_widening(query, 4, 2, 8, 8, eligibility)
    assert_equal(owned.distance_backend_public_switch_count(), widen_before + 1)
    assert_equal(owned.distance_backend_hot_loop_selection_count(), 0)
    assert_true(owned.last_search_distance_evaluations() > 1)

    var path = String(
        "/tmp/akasha-task27-matrix-", metric.name(), "-", scalar.name(), ".bin"
    )
    remove_file_if_exists(path)
    write_file_sync(path, encode_hnsw_snapshot(owned, UInt64(27)))
    var mapped = open_hnsw_snapshot_view(path, config, UInt64(27))
    assert_equal(mapped.distance_backend_selection_count(), 1)
    var mapped_before = mapped.distance_backend_public_switch_count()
    var mapped_results = mapped.search(query, 8, ef_search=8)
    assert_equal(
        mapped.distance_backend_public_switch_count(), mapped_before + 1
    )
    assert_equal(mapped.distance_backend_hot_loop_selection_count(), 0)
    assert_true(mapped.last_search_stats().distance_evaluations > 1)
    assert_equal(len(mapped_results), len(owned_results))
    for result_index in range(len(owned_results)):
        assert_equal(
            mapped_results[result_index].id, owned_results[result_index].id
        )
        _assert_close(
            mapped_results[result_index].score,
            owned_results[result_index].score,
        )
    var mapped_widen_before = mapped.distance_backend_public_switch_count()
    _ = mapped.search_allowed_with_widening(query, 4, 2, 8, eligibility)
    assert_equal(
        mapped.distance_backend_public_switch_count(), mapped_widen_before + 1
    )
    assert_equal(mapped.distance_backend_hot_loop_selection_count(), 0)
    assert_true(mapped.last_search_stats().distance_evaluations > 1)
    mapped.close()
    remove_file_if_exists(path)

    var segmented = SegmentedHnsw(config)
    for id in range(1, 9):
        segmented.upsert(id, _vector(id))
    assert_equal(segmented.distance_backend_selection_count(), 1)
    var segmented_before = segmented.distance_backend_public_switch_count()
    var segmented_results = segmented.search(query, 8, 8, table, _lookup(table))
    assert_equal(
        segmented.distance_backend_public_switch_count(), segmented_before + 1
    )
    assert_equal(segmented.distance_backend_hot_loop_selection_count(), 0)
    assert_true(segmented.last_search_stats().distance_evaluations > 1)
    assert_equal(len(segmented_results), 8)
    var batch_metric = BATCH_COSINE_METRIC
    if metric == MetricKind.dot():
        batch_metric = BATCH_DOT_METRIC
    elif metric == MetricKind.l2():
        batch_metric = BATCH_L2_METRIC
    var scalar_exact = execute_scalar_exact_reported(
        table, query, 8, batch_metric
    )
    _assert_results_equal(segmented_results, scalar_exact.results[0])
    var segmented_widen_before = (
        segmented.distance_backend_public_switch_count()
    )
    _ = segmented.search_allowed(
        query, 4, 2, 8, eligibility, table, _lookup(table)
    )
    assert_equal(
        segmented.distance_backend_public_switch_count(),
        segmented_widen_before + 1,
    )
    assert_equal(segmented.distance_backend_hot_loop_selection_count(), 0)
    assert_true(segmented.last_search_stats().distance_evaluations > 1)


def test_all_enabled_pairs_cross_owned_mapped_segmented_graph_kernels() raises:
    for metric in [MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()]:
        _assert_graph_kernel_pair(metric, ScalarKind.f32())
        _assert_graph_kernel_pair(metric, ScalarKind.bf16())
        _assert_graph_kernel_pair(metric, ScalarKind.f16())
        if metric != MetricKind.l2():
            _assert_graph_kernel_pair(metric, ScalarKind.i8())


def _assert_results_equal(
    actual: List[SearchResult], expected: List[SearchResult]
) raises:
    assert_equal(len(actual), len(expected))
    for result_index in range(len(expected)):
        assert_equal(actual[result_index].id, expected[result_index].id)
        _assert_close(actual[result_index].score, expected[result_index].score)


def test_nonempty_owned_and_mapped_base_share_one_segmented_dispatch() raises:
    var config = _index_config(ScalarKind.f32())
    config.ann_metric = MetricKind.l2()
    var table = MemTable(config.dimension)
    var filtered_table = MemTable(config.dimension)
    var allowed_bitmap = Bitmap(24)
    for id in range(1, 25):
        table.apply_upsert(id, UInt64(id), _vector(id))
        if id % 2 == 1:
            allowed_bitmap.set(id - 1)
            filtered_table.apply_upsert(id, UInt64(id), _vector(id))
    var query = _vector(29)
    var lookup = _lookup(table)
    var allowed = HnswEligibility(allowed_bitmap^, lookup)
    var exact = execute_scalar_exact_reported(table, query, 24, BATCH_L2_METRIC)
    var filtered_exact = execute_scalar_exact_reported(
        filtered_table, query, 12, BATCH_L2_METRIC
    )

    var owned_base = HnswIndex(config)
    for id in range(1, 17):
        owned_base.add(id, _vector(id))
    var snapshot = encode_hnsw_snapshot(owned_base, UInt64(27))
    var owned_segmented = SegmentedHnsw.from_owned(owned_base^)
    for id in range(17, 25):
        owned_segmented.upsert(id, _vector(id))
    assert_equal(owned_segmented.distance_backend_selection_count(), 1)
    var owned_before = owned_segmented.distance_backend_public_switch_count()
    var owned_results = owned_segmented.search(
        query, 24, 24, table, _lookup(table)
    )
    assert_equal(
        owned_segmented.distance_backend_public_switch_count(), owned_before + 1
    )
    assert_equal(owned_segmented.distance_backend_hot_loop_selection_count(), 0)
    assert_true(owned_segmented.last_search_stats().distance_evaluations > 1)
    _assert_results_equal(owned_results, exact.results[0])
    var owned_filtered_before = (
        owned_segmented.distance_backend_public_switch_count()
    )
    var owned_filtered = owned_segmented.search_allowed(
        query, 12, 4, 24, allowed, table, lookup
    )
    assert_equal(owned_segmented.distance_backend_selection_count(), 1)
    assert_equal(
        owned_segmented.distance_backend_public_switch_count(),
        owned_filtered_before + 1,
    )
    assert_equal(owned_segmented.distance_backend_hot_loop_selection_count(), 0)
    assert_true(owned_segmented.last_search_stats().distance_evaluations > 1)
    _assert_results_equal(owned_filtered, filtered_exact.results[0])
    for result in owned_filtered:
        assert_equal(result.id % 2, 1)

    var path = String("/tmp/akasha-task27-segmented-mapped.bin")
    remove_file_if_exists(path)
    write_file_sync(path, snapshot^)
    var mapped_base = open_hnsw_snapshot_view(path, config, UInt64(27))
    var mapped_segmented = SegmentedHnsw.from_mapped(mapped_base^)
    for id in range(17, 25):
        mapped_segmented.upsert(id, _vector(id))
    assert_equal(mapped_segmented.distance_backend_selection_count(), 1)
    var mapped_before = mapped_segmented.distance_backend_public_switch_count()
    var mapped_results = mapped_segmented.search(
        query, 24, 24, table, _lookup(table)
    )
    assert_equal(
        mapped_segmented.distance_backend_public_switch_count(),
        mapped_before + 1,
    )
    assert_equal(
        mapped_segmented.distance_backend_hot_loop_selection_count(), 0
    )
    assert_true(mapped_segmented.last_search_stats().distance_evaluations > 1)
    _assert_results_equal(mapped_results, exact.results[0])
    var mapped_filtered_before = (
        mapped_segmented.distance_backend_public_switch_count()
    )
    var mapped_filtered = mapped_segmented.search_allowed(
        query, 12, 4, 24, allowed, table, lookup
    )
    assert_equal(mapped_segmented.distance_backend_selection_count(), 1)
    assert_equal(
        mapped_segmented.distance_backend_public_switch_count(),
        mapped_filtered_before + 1,
    )
    assert_equal(
        mapped_segmented.distance_backend_hot_loop_selection_count(), 0
    )
    assert_true(mapped_segmented.last_search_stats().distance_evaluations > 1)
    _assert_results_equal(mapped_filtered, filtered_exact.results[0])
    for result in mapped_filtered:
        assert_equal(result.id % 2, 1)
    mapped_segmented.close()
    remove_file_if_exists(path)


def test_execution_policy_keeps_cpu_gpu_fallback_and_hnsw_layers_separate() raises:
    var config = _index_config(ScalarKind.f32())
    var table = MemTable(config.dimension)
    var index = HnswIndex(config)
    for id in range(1, 13):
        var values = _vector(id)
        table.apply_upsert(id, UInt64(id), values.copy())
        index.add(id, values^)
    var query = _vector(17)
    var queries = List[List[Float32]]()
    queries.append(query.copy())
    var exact_execution = execute_exact_batch_reported(
        table, queries, 12, BATCH_DOT_METRIC, 1
    )
    var parallel_execution = execute_parallel_scan_reported(
        table,
        table.live_ordinals(),
        query.copy(),
        12,
        BATCH_DOT_METRIC,
        2,
    )
    var exact = exact_execution.results.copy()
    var parallel = parallel_execution.results.copy()
    var gpu_fallback = execute_device_batch[use_accelerator=False](
        table,
        queries,
        12,
        BATCH_DOT_METRIC,
        GpuExecutionOptions(enabled=True, min_work_items=1),
    )
    var ann = index.search(query, 12, ef_search=12)
    var expected_backend = String("portable-simd-", portable_simd_width())
    assert_equal(exact_execution.stats.backend_name, expected_backend)
    assert_equal(exact_execution.stats.metric_name, "dot")
    assert_equal(exact_execution.stats.scalar_name, "f32")
    assert_equal(exact_execution.stats.fallback_reason, "")
    assert_equal(exact_execution.stats.requested_ef, 0)
    assert_equal(exact_execution.stats.effective_ef, 0)
    assert_equal(exact_execution.stats.visited, 12)
    assert_equal(exact_execution.stats.distance_evaluations, 12)
    assert_equal(parallel_execution.stats.backend_name, expected_backend)
    assert_equal(parallel_execution.stats.metric_name, "dot")
    assert_equal(parallel_execution.stats.scalar_name, "f32")
    assert_equal(parallel_execution.stats.fallback_reason, "")
    assert_equal(parallel_execution.stats.requested_ef, 0)
    assert_equal(parallel_execution.stats.effective_ef, 0)
    assert_equal(parallel_execution.stats.visited, 12)
    assert_equal(parallel_execution.stats.distance_evaluations, 12)
    assert_equal(gpu_fallback.reason, "no accelerator")
    assert_equal(gpu_fallback.stats.backend_name, expected_backend)
    assert_equal(gpu_fallback.stats.metric_name, "dot")
    assert_equal(gpu_fallback.stats.scalar_name, "f32")
    assert_equal(gpu_fallback.stats.fallback_reason, "no accelerator")
    assert_equal(gpu_fallback.stats.requested_ef, 0)
    assert_equal(gpu_fallback.stats.effective_ef, 0)
    assert_equal(gpu_fallback.stats.visited, 12)
    assert_equal(gpu_fallback.stats.distance_evaluations, 12)
    assert_equal(len(exact[0]), len(parallel))
    assert_equal(len(exact[0]), len(gpu_fallback.results[0]))
    for result_index in range(len(exact[0])):
        assert_equal(parallel[result_index].id, exact[0][result_index].id)
        assert_equal(parallel[result_index].score, exact[0][result_index].score)
        assert_equal(
            gpu_fallback.results[0][result_index].id,
            exact[0][result_index].id,
        )
        assert_equal(
            gpu_fallback.results[0][result_index].score,
            exact[0][result_index].score,
        )
    for ann_result in ann:
        var found = False
        for exact_result in exact[0]:
            if ann_result.id == exact_result.id:
                assert_equal(ann_result.score, exact_result.score)
                found = True
                break
        assert_true(found)
    assert_equal(index.last_search_stats.metric_name, "dot")
    assert_equal(index.last_search_stats.scalar_name, "f32")
    assert_equal(index.last_search_stats.backend_name, expected_backend)
    assert_equal(index.last_search_stats.fallback_reason, "")
    assert_equal(index.last_search_stats.requested_ef, 12)
    assert_equal(index.last_search_stats.effective_ef, 12)
    assert_true(index.last_search_stats.base_visited > 0)
    assert_equal(
        index.last_search_stats.distance_evaluations,
        index.last_search_stats.upper_visited
        + index.last_search_stats.base_visited,
    )
    assert_equal(index.distance_backend_selection_count(), 1)
    assert_equal(index.distance_backend_hot_loop_selection_count(), 0)


def test_scalar_exact_and_deterministic_gpu_stats_report_real_backend() raises:
    var table = MemTable(4)
    for id in range(1, 9):
        table.apply_upsert(id, UInt64(id), _vector(id))
    var scalar = execute_scalar_exact_reported(
        table, _vector(19), 8, BATCH_DOT_METRIC
    )
    assert_equal(scalar.stats.backend_name, "scalar-f32")
    assert_equal(scalar.stats.metric_name, "dot")
    assert_equal(scalar.stats.scalar_name, "f32")
    assert_equal(scalar.stats.distance_evaluations, 8)
    var gpu = _execution_stats(BATCH_DOT_METRIC, "", True, 8)
    assert_equal(gpu.backend_name, "gpu")
    assert_equal(gpu.fallback_reason, "")
    var mixed = _candidate_execution_stats(
        BATCH_DOT_METRIC, "partial GPU execution", True, True, 8
    )
    assert_equal(mixed.backend_name, "mixed")
    assert_equal(mixed.fallback_reason, "partial GPU execution")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
