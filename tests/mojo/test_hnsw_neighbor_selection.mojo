from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_core import (
    _search_item_better,
    select_neighbors_heuristic,
)
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_stats import HnswBuildStats
from akasha.index.hnsw_storage import HnswStorage
from std.math import inf, nan
from std.testing import (
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)


def _vector(x: Float32, y: Float32) -> List[Float32]:
    var values: List[Float32] = [x, y]
    return values^


def _append(
    mut graph: HnswStorage,
    dispatcher: MetricDispatcher,
    id: Int,
    x: Float32,
    y: Float32,
) raises -> UInt32:
    var raw = _vector(x, y)
    var prepared = dispatcher.prepare_graph_vector(raw^)
    return graph.append(id, prepared^, 0)


def _candidate(
    graph: HnswStorage,
    dispatcher: MetricDispatcher,
    query: List[Float32],
    slot: UInt32,
) raises -> HnswHeapItem:
    return HnswHeapItem(
        slot,
        graph.id_at(slot),
        graph.distance_to_slot(dispatcher, query, slot),
    )


def _none() -> Optional[UInt32]:
    return Optional[UInt32]()


def _some(slot: UInt32) -> Optional[UInt32]:
    return Optional(slot)


def _assert_slots(actual: List[UInt32], expected: List[UInt32]) raises:
    assert_equal(len(actual), len(expected))
    for index in range(len(expected)):
        assert_equal(actual[index], expected[index])


def test_diversity_rejects_redundant_collinear_neighbor() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var nearest = _append(graph, metric, 10, 1.0, 0.0)
    var redundant = _append(graph, metric, 20, 2.0, 0.0)
    var different_direction = _append(graph, metric, 30, 0.0, 2.0)
    var raw_query = _vector(0.0, 0.0)
    var query = metric.prepare_query(raw_query^)
    var candidates: List[HnswHeapItem] = [
        _candidate(graph, metric, query, nearest),
        _candidate(graph, metric, query, redundant),
        _candidate(graph, metric, query, different_direction),
    ]
    var stats = HnswBuildStats()
    stats.slot_count = 99
    stats.directed_edges = 17

    var selected = select_neighbors_heuristic(
        graph, metric, candidates, _none(), 2, False, stats
    )

    var expected: List[UInt32] = [nearest, different_direction]
    _assert_slots(selected, expected)
    # redundant-nearest and different-direction-nearest are the only pairs.
    assert_equal(stats.distance_evaluations, 2)
    assert_equal(stats.slot_count, 99)
    assert_equal(stats.directed_edges, 17)


def test_capacity_zero_and_one_do_no_pair_distance_work() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var farther = _append(graph, metric, 20, 2.0, 0.0)
    var nearer = _append(graph, metric, 10, 1.0, 0.0)
    var candidates: List[HnswHeapItem] = [
        HnswHeapItem(farther, 20, 4.0),
        HnswHeapItem(nearer, 10, 1.0),
    ]
    var zero_stats = HnswBuildStats()
    var zero = select_neighbors_heuristic(
        graph, metric, candidates, _none(), 0, False, zero_stats
    )
    assert_equal(len(zero), 0)
    assert_equal(zero_stats.distance_evaluations, 0)

    var one_stats = HnswBuildStats()
    var one = select_neighbors_heuristic(
        graph, metric, candidates, _none(), 1, False, one_stats
    )
    var expected: List[UInt32] = [nearer]
    _assert_slots(one, expected)
    assert_equal(one_stats.distance_evaluations, 0)

    # Capacity is a bound, not an allocation request: an arbitrarily large
    # caller value is clamped to the validated unique candidate count.
    var large_stats = HnswBuildStats()
    var large = select_neighbors_heuristic(
        graph, metric, candidates, _none(), Int.MAX, True, large_stats
    )
    var both: List[UInt32] = [nearer, farther]
    _assert_slots(large, both)
    assert_equal(large_stats.distance_evaluations, 1)


def test_duplicates_and_excluded_self_are_skipped_without_distance_work() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var self_slot = _append(graph, metric, 5, 0.0, 0.0)
    var first = _append(graph, metric, 10, 1.0, 0.0)
    var second = _append(graph, metric, 20, 0.0, 1.0)
    var candidates: List[HnswHeapItem] = [
        HnswHeapItem(second, 20, 1.0),
        HnswHeapItem(self_slot, 5, 0.0),
        HnswHeapItem(first, 10, 1.0),
        HnswHeapItem(first, 10, 1.0),
        HnswHeapItem(second, 20, 1.0),
    ]
    var stats = HnswBuildStats()

    var selected = select_neighbors_heuristic(
        graph, metric, candidates, _some(self_slot), 4, False, stats
    )

    var expected: List[UInt32] = [first, second]
    _assert_slots(selected, expected)
    # Only second-to-first is a real candidate-to-selected calculation.
    assert_equal(stats.distance_evaluations, 1)


def test_equality_boundary_is_accepted() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var first = _append(graph, metric, 10, 1.0, 0.0)
    var equal_boundary = _append(graph, metric, 20, 0.5, 1.0)
    var candidates: List[HnswHeapItem] = [
        HnswHeapItem(first, 10, 1.0),
        HnswHeapItem(equal_boundary, 20, 1.25),
    ]
    var stats = HnswBuildStats()

    var selected = select_neighbors_heuristic(
        graph, metric, candidates, _none(), 2, False, stats
    )

    var expected: List[UInt32] = [first, equal_boundary]
    _assert_slots(selected, expected)
    assert_equal(stats.distance_evaluations, 1)


def test_keep_pruned_fills_capacity_in_rejected_nearest_order() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var nearest = _append(graph, metric, 10, 1.0, 0.0)
    var first_rejected = _append(graph, metric, 20, 2.0, 0.0)
    var diverse = _append(graph, metric, 30, -2.0, 0.0)
    var later_rejected = _append(graph, metric, 40, 3.0, 0.0)
    var candidates: List[HnswHeapItem] = [
        HnswHeapItem(later_rejected, 40, 9.0),
        HnswHeapItem(diverse, 30, 4.0),
        HnswHeapItem(first_rejected, 20, 4.0),
        HnswHeapItem(nearest, 10, 1.0),
    ]
    var stats = HnswBuildStats()

    var selected = select_neighbors_heuristic(
        graph, metric, candidates, _none(), 3, True, stats
    )

    var expected: List[UInt32] = [nearest, diverse, first_rejected]
    _assert_slots(selected, expected)
    # B-A, C-A, D-A. D is rejected on its first pair.
    assert_equal(stats.distance_evaluations, 3)


def test_input_permutations_have_identical_deterministic_output() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var a = _append(graph, metric, 30, 1.0, 0.0)
    var b = _append(graph, metric, 10, 0.0, 1.0)
    var c = _append(graph, metric, 20, -1.0, 0.0)
    var forward: List[HnswHeapItem] = [
        HnswHeapItem(a, 30, 1.0),
        HnswHeapItem(b, 10, 1.0),
        HnswHeapItem(c, 20, 1.0),
        HnswHeapItem(a, 30, 1.0),
    ]
    var reverse: List[HnswHeapItem] = [
        HnswHeapItem(a, 30, 1.0),
        HnswHeapItem(c, 20, 1.0),
        HnswHeapItem(b, 10, 1.0),
        HnswHeapItem(a, 30, 1.0),
    ]
    var first_stats = HnswBuildStats()
    var second_stats = HnswBuildStats()
    var first = select_neighbors_heuristic(
        graph, metric, forward, _none(), 3, False, first_stats
    )
    var second = select_neighbors_heuristic(
        graph, metric, reverse, _none(), 3, False, second_stats
    )

    var expected: List[UInt32] = [b, c, a]
    _assert_slots(first, expected)
    _assert_slots(second, expected)
    assert_equal(first_stats.distance_evaluations, 3)
    assert_equal(second_stats.distance_evaluations, 3)


def test_candidate_order_uses_public_id_then_slot_ties() raises:
    var lower_id = HnswHeapItem(UInt32(9), 10, 1.0)
    var higher_id = HnswHeapItem(UInt32(0), 20, 1.0)
    assert_true(_search_item_better(lower_id, higher_id))

    # Equal public IDs cannot both be current in valid HnswStorage, but the
    # comparator retains the defensive slot tertiary required by persisted
    # or intermediate candidate streams.
    var lower_slot = HnswHeapItem(UInt32(1), 10, 1.0)
    var higher_slot = HnswHeapItem(UInt32(2), 10, 1.0)
    assert_true(_search_item_better(lower_slot, higher_slot))


def test_inactive_candidate_is_rejected_before_stats_mutate() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var inactive = _append(graph, metric, 10, 1.0, 0.0)
    assert_true(graph.mark_deleted(10))
    var candidates: List[HnswHeapItem] = [
        HnswHeapItem(inactive, 10, 1.0)
    ]
    var stats = HnswBuildStats()
    stats.distance_evaluations = 7
    with assert_raises():
        _ = select_neighbors_heuristic(
            graph, metric, candidates, _none(), 1, False, stats
        )
    assert_equal(stats.distance_evaluations, 7)


def test_invalid_candidate_fields_and_excluded_slot_preserve_stats() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var slot = _append(graph, metric, 10, 1.0, 0.0)
    var stats = HnswBuildStats()
    stats.distance_evaluations = 11

    var invalid_slot: List[HnswHeapItem] = [
        HnswHeapItem(UInt32(99), 10, 1.0)
    ]
    with assert_raises():
        _ = select_neighbors_heuristic(
            graph, metric, invalid_slot, _none(), 1, False, stats
        )

    var invalid_id: List[HnswHeapItem] = [HnswHeapItem(slot, 99, 1.0)]
    with assert_raises():
        _ = select_neighbors_heuristic(
            graph, metric, invalid_id, _none(), 1, False, stats
        )

    var invalid_nan: List[HnswHeapItem] = [
        HnswHeapItem(slot, 10, nan[DType.float32]())
    ]
    with assert_raises():
        _ = select_neighbors_heuristic(
            graph, metric, invalid_nan, _none(), 1, False, stats
        )

    var invalid_inf: List[HnswHeapItem] = [
        HnswHeapItem(slot, 10, inf[DType.float32]())
    ]
    with assert_raises():
        _ = select_neighbors_heuristic(
            graph, metric, invalid_inf, _none(), 1, False, stats
        )

    var invalid_negative: List[HnswHeapItem] = [
        HnswHeapItem(slot, 10, -1.0)
    ]
    with assert_raises():
        _ = select_neighbors_heuristic(
            graph, metric, invalid_negative, _none(), 1, False, stats
        )

    with assert_raises():
        _ = select_neighbors_heuristic(
            graph, metric, invalid_id, _some(UInt32(99)), 1, False, stats
        )
    with assert_raises():
        _ = select_neighbors_heuristic(
            graph, metric, invalid_id, _none(), -1, False, stats
        )
    assert_equal(stats.distance_evaluations, 11)


def test_invalid_dispatcher_backend_and_dimension_preserve_stats() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var slot = _append(graph, metric, 10, 1.0, 0.0)
    var candidates: List[HnswHeapItem] = [HnswHeapItem(slot, 10, 1.0)]
    var stats = HnswBuildStats()
    stats.distance_evaluations = 13

    var wrong_dimension = MetricDispatcher(
        MetricKind.l2(), ScalarKind.f32(), 3
    )
    with assert_raises():
        _ = select_neighbors_heuristic(
            graph,
            wrong_dimension,
            candidates,
            _none(),
            1,
            False,
            stats,
        )
    var unsupported = MetricDispatcher(
        MetricKind.cosine(), ScalarKind.bf16(), 2
    )
    with assert_raises():
        _ = select_neighbors_heuristic(
            graph, unsupported, candidates, _none(), 1, False, stats
        )
    assert_equal(stats.distance_evaluations, 13)


def test_dot_allows_negative_canonical_candidate_distance() raises:
    var metric = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var slot = _append(graph, metric, 10, 1.0, 0.0)
    var candidates: List[HnswHeapItem] = [HnswHeapItem(slot, 10, -2.0)]
    var stats = HnswBuildStats()
    var selected = select_neighbors_heuristic(
        graph, metric, candidates, _none(), 1, False, stats
    )
    var expected: List[UInt32] = [slot]
    _assert_slots(selected, expected)
    assert_equal(stats.distance_evaluations, 0)


def test_prepared_cosine_uses_same_canonical_heuristic() raises:
    var metric = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 4, 8)
    var same_direction = _append(graph, metric, 10, 1.0, 0.0)
    var orthogonal = _append(graph, metric, 20, 0.0, 1.0)
    var raw_query = _vector(1.0, 0.0)
    var query = metric.prepare_query(raw_query^)
    var candidates: List[HnswHeapItem] = [
        _candidate(graph, metric, query, same_direction),
        _candidate(graph, metric, query, orthogonal),
    ]
    var stats = HnswBuildStats()
    var selected = select_neighbors_heuristic(
        graph, metric, candidates, _none(), 2, False, stats
    )
    var expected: List[UInt32] = [same_direction, orthogonal]
    _assert_slots(selected, expected)
    assert_equal(stats.distance_evaluations, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
