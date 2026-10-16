from hnsw_search_helpers import greedy_descent, search_layer
from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_core import (
    HnswSearchAdmission,
    HnswSearchStats,
)
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_search import search_entry, search_level
from akasha.index.hnsw_storage import HnswStorage
from std.testing import (
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)


def _metric() raises -> MetricDispatcher:
    return MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 1)


def _value(value: Float32) -> List[Float32]:
    var values: List[Float32] = [value]
    return values^


def _append(
    mut graph: HnswStorage, id: Int, value: Float32, level: Int = 0
) raises -> UInt32:
    var values = _value(value)
    return graph.append(id, values^, level)


def _set(
    mut graph: HnswStorage,
    slot: Int,
    level: Int,
    neighbors: List[UInt32],
) raises:
    graph.set_neighbors(UInt32(slot), level, neighbors)


def _query(value: Float32) -> List[Float32]:
    return _value(value)


def _assert_item(
    results: List[HnswHeapItem],
    index: Int,
    slot: Int,
    id: Int,
    distance: Float32,
) raises:
    assert_equal(results[index].slot, UInt32(slot))
    assert_equal(results[index].id, id)
    assert_equal(results[index].distance, distance)


def test_upper_seeds_reach_another_base_component_without_rescoring() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 0, 5.0, 1)
    _ = _append(graph, 1, 1.0, 1)
    _ = _append(graph, 2, 2.0, 1)
    _ = _append(graph, 3, 3.0, 1)
    _ = _append(graph, 4, 0.0)
    _set(graph, 0, 1, [UInt32(1), UInt32(2), UInt32(3)])
    # Repeat an upper candidate to exercise unique retention.
    _set(graph, 1, 1, [UInt32(2)])
    _set(graph, 2, 0, [UInt32(4), UInt32(1)])
    var metric = _metric()
    var query = _query(0.0)
    var allowed = HnswSearchAdmission()
    var baseline_scratch = HnswSearchScratch()
    var baseline_stats = HnswSearchStats()
    var baseline = search_entry(
        graph, metric, query, UInt32(0), 1, 0, allowed,
        baseline_scratch, baseline_stats,
    )
    var baseline_result = search_level(
        graph, metric, query, baseline, 0, 2, allowed,
        baseline_scratch, baseline_stats,
    )
    assert_equal(len(baseline_result), 1)
    assert_equal(baseline_result[0].id, 1)

    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var entry = search_entry[collect_seeds=True](
        graph, metric, query, UInt32(0), 1, 0, allowed, scratch, stats,
        seed_ef=2,
    )
    var seeds = scratch.results.take_sorted_best()
    assert_equal(entry.slot, baseline.slot)
    assert_equal(stats.distance_evaluations, baseline_stats.distance_evaluations)
    assert_equal(len(seeds), 2)
    _assert_item(seeds, 0, 1, 1, 1.0)
    _assert_item(seeds, 1, 2, 2, 4.0)
    var results = search_level(
        graph, metric, query, entry, 0, 2, allowed, scratch, stats,
        seeds=seeds,
    )
    _assert_item(results, 0, 4, 4, 0.0)
    _assert_item(results, 1, 1, 1, 1.0)
    assert_equal(stats.distance_evaluations, baseline_stats.distance_evaluations + 1)
    assert_equal(stats.base_visited, 3)
    assert_equal(scratch.result_reserved_capacity(), 2)


def test_upper_seed_collection_filters_and_handles_level_zero() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 0, 5.0, 1)
    _ = _append(graph, 1, 0.0, 1)
    _ = _append(graph, 2, 2.0, 1)
    _set(graph, 0, 1, [UInt32(1), UInt32(2)])
    var metric = _metric()
    var query = _query(0.0)
    var allowed = HnswSearchAdmission([True, False, True])
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    _ = search_entry[collect_seeds=True](
        graph, metric, query, UInt32(0), 1, 0, allowed, scratch, stats,
        seed_ef=2,
    )
    var seeds = scratch.results.take_sorted_best()
    assert_equal(len(seeds), 2)
    assert_equal(seeds[0].id, 2)
    assert_equal(seeds[1].id, 0)
    assert_equal(stats.distance_evaluations, 2)
    assert_equal(stats.filtered_rejections, 1)
    scratch._force_epoch_for_test(UInt32.MAX)
    _ = search_entry[collect_seeds=True](
        graph, metric, query, UInt32(2), 0, 0, allowed, scratch, stats,
        seed_ef=2,
    )
    seeds = scratch.results.take_sorted_best()
    assert_equal(len(seeds), 1)
    assert_equal(seeds[0].id, 2)
    assert_equal(scratch.epoch, UInt32(1))
    assert_equal(stats.distance_evaluations, 3)


def test_base_seeds_reject_invalid_inputs_before_changing_scratch() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 0, 1.0)
    _ = _append(graph, 1, 2.0)
    var metric = _metric()
    var query = _query(0.0)
    var allowed = HnswSearchAdmission([True, False])
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var entry = HnswHeapItem(UInt32(0), 0, 1.0)
    var invalid: List[HnswHeapItem] = [HnswHeapItem(UInt32(2), 2, 0.0)]
    with assert_raises():
        _ = search_level(graph, metric, query, entry, 0, 2, allowed, scratch, stats, seeds=invalid)
    invalid[0] = HnswHeapItem(UInt32(1), 1, 4.0)
    with assert_raises():
        _ = search_level(graph, metric, query, entry, 0, 2, allowed, scratch, stats, seeds=invalid)
    invalid = [entry, entry]
    with assert_raises():
        _ = search_level(graph, metric, query, entry, 0, 1, allowed, scratch, stats, seeds=invalid)
    assert_equal(scratch.epoch, UInt32(0))
    assert_equal(stats.base_visited, 0)
    # Repeated initial slots are visited once when the list is within ef.
    var result = search_level(graph, metric, query, entry, 0, 2, allowed, scratch, stats, seeds=invalid)
    assert_equal(len(result), 1)
    assert_equal(stats.base_visited, 1)
    assert_equal(stats.distance_evaluations, 0)


def test_upper_greedy_descends_multiple_hops_and_stops_locally() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 40, 8.0, 1)
    _ = _append(graph, 30, 5.0, 1)
    _ = _append(graph, 20, 1.0, 1)
    _ = _append(graph, 10, 3.0, 1)
    var from_zero: List[UInt32] = [UInt32(1)]
    var from_one: List[UInt32] = [UInt32(0), UInt32(2), UInt32(3)]
    var from_two: List[UInt32] = [UInt32(1), UInt32(3)]
    var from_three: List[UInt32] = [UInt32(1), UInt32(2)]
    _set(graph, 0, 1, from_zero^)
    _set(graph, 1, 1, from_one^)
    _set(graph, 2, 1, from_two^)
    _set(graph, 3, 1, from_three^)

    var metric = _metric()
    var query = _query(0.0)
    var stats = HnswSearchStats()
    var actual = greedy_descent(graph, metric, query, UInt32(0), 1, stats)

    assert_equal(actual.slot, UInt32(2))
    assert_equal(actual.distance, Float32(1.0))
    # Qdrant rescans each expanded row; repeated neighbors are scored again.
    assert_equal(stats.upper_visited, 7)
    assert_equal(stats.base_visited, 0)
    assert_equal(stats.distance_evaluations, 7)


def test_upper_greedy_moves_only_on_strictly_better_distance() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 50, 5.0, 1)
    _ = _append(graph, 20, 3.0, 1)
    _ = _append(graph, 10, -3.0, 1)
    var neighbors: List[UInt32] = [UInt32(1), UInt32(2)]
    _set(graph, 0, 1, neighbors^)
    var none: List[UInt32] = []
    _set(graph, 1, 1, none.copy())
    _set(graph, 2, 1, none^)

    var metric = _metric()
    var query = _query(0.0)
    var stats = HnswSearchStats()
    var actual = greedy_descent(graph, metric, query, UInt32(0), 1, stats)

    assert_equal(actual.slot, UInt32(1))
    assert_equal(actual.distance, Float32(9.0))
    assert_equal(stats.upper_visited, 3)
    assert_equal(stats.distance_evaluations, 3)


def test_base_search_returns_connected_results_best_first() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 40, 4.0)
    _ = _append(graph, 30, 3.0)
    _ = _append(graph, 10, 1.0)
    _ = _append(graph, 20, -1.0)
    var n0: List[UInt32] = [UInt32(1)]
    var n1: List[UInt32] = [UInt32(0), UInt32(2)]
    var n2: List[UInt32] = [UInt32(1), UInt32(3)]
    var n3: List[UInt32] = [UInt32(2)]
    _set(graph, 0, 0, n0^)
    _set(graph, 1, 0, n1^)
    _set(graph, 2, 0, n2^)
    _set(graph, 3, 0, n3^)

    var metric = _metric()
    var query = _query(0.0)
    var admission = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var results = search_layer(
        graph, metric, query, UInt32(0), 0, 4, 4, admission, scratch, stats
    )

    assert_equal(len(results), 4)
    _assert_item(results, 0, 2, 10, 1.0)
    _assert_item(results, 1, 3, 20, 1.0)
    _assert_item(results, 2, 1, 30, 9.0)
    _assert_item(results, 3, 0, 40, 16.0)
    assert_equal(stats.base_visited, 4)
    assert_equal(stats.distance_evaluations, 4)
    assert_equal(stats.retained_candidates, 4)


def test_radius_termination_does_not_expand_far_branch() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 0, 0.0)
    _ = _append(graph, 1, 1.0)
    _ = _append(graph, 10, 10.0)
    _ = _append(graph, 20, 20.0)
    var root: List[UInt32] = [UInt32(1), UInt32(2)]
    var near: List[UInt32] = [UInt32(0)]
    var far: List[UInt32] = [UInt32(0), UInt32(3)]
    var tail: List[UInt32] = [UInt32(2)]
    _set(graph, 0, 0, root^)
    _set(graph, 1, 0, near^)
    _set(graph, 2, 0, far^)
    _set(graph, 3, 0, tail^)

    var metric = _metric()
    var query = _query(0.0)
    var admission = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var results = search_layer(
        graph, metric, query, UInt32(0), 0, 2, 2, admission, scratch, stats
    )

    assert_equal(len(results), 2)
    _assert_item(results, 0, 0, 0, 0.0)
    _assert_item(results, 1, 1, 1, 1.0)
    assert_equal(stats.base_visited, 3)
    assert_equal(stats.distance_evaluations, 3)
    assert_equal(stats.retained_candidates, 2)


def test_rejected_nearest_tie_does_not_enter_frontier() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 10, 1.0)
    _ = _append(graph, 20, -1.0)
    _ = _append(graph, 5, 0.0)
    var entry: List[UInt32] = [UInt32(1)]
    var bridge: List[UInt32] = [UInt32(0), UInt32(2)]
    var target: List[UInt32] = [UInt32(1)]
    _set(graph, 0, 0, entry^)
    _set(graph, 1, 0, bridge^)
    _set(graph, 2, 0, target^)

    var metric = _metric()
    var query = _query(0.0)
    var admission = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var results = search_layer(
        graph, metric, query, UInt32(0), 0, 1, 1, admission, scratch, stats
    )

    # Only nearest-queue admissions enter the frontier. A rejected tie
    # cannot expose its closer neighbor.
    assert_equal(len(results), 1)
    _assert_item(results, 0, 0, 10, 1.0)
    assert_equal(stats.base_visited, 2)
    assert_equal(stats.distance_evaluations, 2)
    assert_equal(stats.retained_candidates, 1)


def test_equal_radius_candidate_is_not_stopped_by_worse_id() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 10, 0.0)
    _ = _append(graph, 30, 1.0)
    _ = _append(graph, 20, -1.0)
    _ = _append(graph, 5, 0.0)
    var entry: List[UInt32] = [UInt32(1), UInt32(2)]
    var bridge: List[UInt32] = [UInt32(0), UInt32(3)]
    var better_tie: List[UInt32] = [UInt32(0)]
    var target: List[UInt32] = [UInt32(1)]
    _set(graph, 0, 0, entry^)
    _set(graph, 1, 0, bridge^)
    _set(graph, 2, 0, better_tie^)
    _set(graph, 3, 0, target^)

    var metric = _metric()
    var query = _query(0.0)
    var admission = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var results = search_layer(
        graph, metric, query, UInt32(0), 0, 2, 2, admission, scratch, stats
    )

    # Slot one was queued before the result radius became the equal-distance
    # slot two. A larger ID cannot terminate its traversal at equal distance.
    assert_equal(len(results), 2)
    _assert_item(results, 0, 3, 5, 0.0)
    _assert_item(results, 1, 0, 10, 0.0)
    assert_equal(stats.base_visited, 4)
    assert_equal(stats.distance_evaluations, 4)
    assert_equal(stats.retained_candidates, 2)


def test_disconnected_slots_are_not_visited() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 1, 1.0)
    _ = _append(graph, 2, 2.0)
    _ = _append(graph, 3, 0.0)
    var a: List[UInt32] = [UInt32(1)]
    var b: List[UInt32] = [UInt32(0)]
    _set(graph, 0, 0, a^)
    _set(graph, 1, 0, b^)

    var metric = _metric()
    var query = _query(0.0)
    var admission = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var results = search_layer(
        graph, metric, query, UInt32(0), 0, 8, 8, admission, scratch, stats
    )
    assert_equal(len(results), 2)
    assert_equal(stats.base_visited, 2)
    assert_equal(stats.distance_evaluations, 2)


def test_inactive_entry_cannot_seed_a_layer() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 50, 3.0)
    _ = _append(graph, 10, 0.0)
    var bridge: List[UInt32] = [UInt32(1)]
    var target: List[UInt32] = [UInt32(0)]
    _set(graph, 0, 0, bridge^)
    _set(graph, 1, 0, target^)
    assert_equal(graph.mark_replaced(50), UInt32(0))
    _ = _append(graph, 50, 100.0)

    var metric = _metric()
    var query = _query(0.0)
    var admission = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var results = search_layer(
        graph, metric, query, UInt32(0), 0, 4, 4, admission, scratch, stats
    )

    assert_equal(len(results), 0)
    assert_equal(stats.base_visited, 0)
    assert_equal(stats.inactive_rejections, 0)
    assert_equal(stats.filtered_rejections, 0)


def test_deleted_middle_slot_is_filtered_before_scoring() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 30, 3.0)
    _ = _append(graph, 20, 2.0)
    _ = _append(graph, 10, 0.0)
    var root: List[UInt32] = [UInt32(1)]
    var bridge: List[UInt32] = [UInt32(0), UInt32(2)]
    var target: List[UInt32] = [UInt32(1)]
    _set(graph, 0, 0, root^)
    _set(graph, 1, 0, bridge^)
    _set(graph, 2, 0, target^)
    assert_true(graph.mark_deleted(20))

    var metric = _metric()
    var query = _query(0.0)
    var admission = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var results = search_layer(
        graph, metric, query, UInt32(0), 0, 3, 3, admission, scratch, stats
    )

    assert_equal(len(results), 1)
    _assert_item(results, 0, 0, 30, 9.0)
    assert_equal(stats.base_visited, 1)
    assert_equal(stats.distance_evaluations, 1)
    assert_equal(stats.inactive_rejections, 1)


def test_rejected_slots_are_unvisited_and_checked_from_each_row() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 30, 3.0)
    _ = _append(graph, 20, 2.0)
    _ = _append(graph, 10, 0.0)
    _ = _append(graph, 40, 4.0)
    _ = _append(graph, 5, 0.0)
    var root: List[UInt32] = [UInt32(1), UInt32(3)]
    var left: List[UInt32] = [UInt32(0), UInt32(2)]
    var target: List[UInt32] = [UInt32(1), UInt32(3), UInt32(4)]
    var right: List[UInt32] = [UInt32(0), UInt32(2)]
    var final_target: List[UInt32] = [UInt32(2)]
    _set(graph, 0, 0, root^)
    _set(graph, 1, 0, left^)
    _set(graph, 2, 0, target^)
    _set(graph, 3, 0, right^)
    _set(graph, 4, 0, final_target^)
    # Slot two is encountered from slots one and three. Filtering does not
    # mark it visited, and neither encounter can reach slot four.
    var flags: List[Bool] = [True, True, False, True, True]
    var admission = HnswSearchAdmission(flags^)
    assert_true(admission.allows(UInt32(0)))
    assert_true(not admission.allows(UInt32(2)))

    var metric = _metric()
    var query = _query(0.0)
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var results = search_layer(
        graph, metric, query, UInt32(0), 0, 5, 5, admission, scratch, stats
    )

    assert_equal(len(results), 3)
    _assert_item(results, 0, 1, 20, 4.0)
    assert_equal(stats.base_visited, 3)
    assert_equal(stats.distance_evaluations, 3)
    assert_equal(stats.filtered_rejections, 2)
    assert_equal(stats.inactive_rejections, 0)


def test_disallowed_entry_cannot_seed_a_layer() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 20, 2.0)
    _ = _append(graph, 10, 0.0)
    var a: List[UInt32] = [UInt32(1)]
    var b: List[UInt32] = [UInt32(0)]
    _set(graph, 0, 0, a^)
    _set(graph, 1, 0, b^)
    var flags: List[Bool] = [False, True]
    var admission = HnswSearchAdmission(flags^)

    var metric = _metric()
    var query = _query(0.0)
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var results = search_layer(
        graph, metric, query, UInt32(0), 0, 2, 2, admission, scratch, stats
    )
    assert_equal(len(results), 0)
    assert_equal(stats.filtered_rejections, 0)
    assert_equal(stats.base_visited, 0)


def test_invalid_inputs_do_not_mutate_scratch_or_stats() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 10, 0.0)
    var metric = _metric()
    var good_query = _query(0.0)
    var bad_query: List[Float32] = [0.0, 1.0]
    var admission = HnswSearchAdmission()
    var bad_flags: List[Bool] = [True, False]
    var bad_admission = HnswSearchAdmission(bad_flags^)
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()

    with assert_raises():
        _ = search_layer(
            graph,
            metric,
            good_query,
            UInt32(0),
            0,
            0,
            1,
            admission,
            scratch,
            stats,
        )
    with assert_raises():
        _ = search_layer(
            graph,
            metric,
            good_query,
            UInt32(0),
            0,
            1,
            0,
            admission,
            scratch,
            stats,
        )
    with assert_raises():
        _ = search_layer(
            graph,
            metric,
            good_query,
            UInt32(0),
            0,
            2,
            1,
            admission,
            scratch,
            stats,
        )
    with assert_raises():
        _ = search_layer(
            graph,
            metric,
            bad_query,
            UInt32(0),
            0,
            2,
            2,
            admission,
            scratch,
            stats,
        )
    with assert_raises():
        _ = search_layer(
            graph,
            metric,
            good_query,
            UInt32(9),
            0,
            2,
            2,
            admission,
            scratch,
            stats,
        )
    with assert_raises():
        _ = search_layer(
            graph,
            metric,
            good_query,
            UInt32(0),
            1,
            2,
            2,
            admission,
            scratch,
            stats,
        )
    with assert_raises():
        _ = search_layer(
            graph,
            metric,
            good_query,
            UInt32(0),
            0,
            2,
            2,
            bad_admission,
            scratch,
            stats,
        )
    assert_equal(scratch.epoch, UInt32(0))
    assert_equal(stats.upper_visited, 0)
    assert_equal(stats.base_visited, 0)
    assert_equal(stats.distance_evaluations, 0)


def test_invalid_cross_level_edge_is_rejected_before_stats_mutate() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 20, 2.0, 1)
    _ = _append(graph, 10, 0.0, 0)
    var invalid_upper_edge: List[UInt32] = [UInt32(1)]
    _set(graph, 0, 1, invalid_upper_edge^)
    var metric = _metric()
    var query = _query(0.0)
    var stats = HnswSearchStats()
    with assert_raises():
        _ = greedy_descent(graph, metric, query, UInt32(0), 1, stats)
    assert_equal(stats.upper_visited, 0)
    assert_equal(stats.distance_evaluations, 0)


def test_k_less_than_ef_and_scratch_reuse_across_searches() raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 20, 2.0)
    _ = _append(graph, 10, 0.0)
    var a: List[UInt32] = [UInt32(1)]
    var b: List[UInt32] = [UInt32(0)]
    _set(graph, 0, 0, a^)
    _set(graph, 1, 0, b^)
    var metric = _metric()
    var admission = HnswSearchAdmission()
    var scratch = HnswSearchScratch()

    var first_stats = HnswSearchStats()
    var first_query = _query(0.0)
    var first = search_layer(
        graph,
        metric,
        first_query,
        UInt32(0),
        0,
        1,
        2,
        admission,
        scratch,
        first_stats,
    )
    assert_equal(len(first), 1)
    _assert_item(first, 0, 1, 10, 0.0)
    assert_equal(scratch.epoch, UInt32(1))

    var second_stats = HnswSearchStats()
    var second_query = _query(2.0)
    var second = search_layer(
        graph,
        metric,
        second_query,
        UInt32(1),
        0,
        1,
        2,
        admission,
        scratch,
        second_stats,
    )
    assert_equal(len(second), 1)
    _assert_item(second, 0, 0, 20, 0.0)
    assert_equal(scratch.epoch, UInt32(2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
