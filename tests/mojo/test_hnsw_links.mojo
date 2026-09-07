from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_core import (
    connect_bidirectional,
    greedy_descent,
    HnswValidationStats,
    validate_bidirectional_links,
    validate_bidirectional_links_with_stats,
)
from akasha.index.hnsw_stats import HnswBuildStats, HnswSearchStats
from akasha.index.hnsw_storage import HnswStorage
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _vector(x: Float32, y: Float32) -> List[Float32]:
    var values: List[Float32] = [x, y]
    return values^


def _append(
    mut graph: HnswStorage,
    metric: MetricDispatcher,
    id: Int,
    x: Float32,
    y: Float32,
    level: Int = 0,
) raises -> UInt32:
    var raw = _vector(x, y)
    var prepared = metric.prepare_graph_vector(raw^)
    return graph.append(id, prepared^, level)


def _connect(
    mut graph: HnswStorage,
    metric: MetricDispatcher,
    endpoint: UInt32,
    level: Int,
    var selected: List[UInt32],
    mut stats: HnswBuildStats,
) raises:
    connect_bidirectional(
        graph, metric, endpoint, level, selected^, stats
    )


def _assert_symmetric_and_bounded(graph: HnswStorage) raises:
    validate_bidirectional_links(graph)
    for index in range(graph.slot_count()):
        var slot = UInt32(index)
        for level in range(graph.level(slot) + 1):
            var count = graph.neighbor_count(slot, level)
            assert_true(count <= graph.level_capacity(slot, level))
            for edge_index in range(count):
                var neighbor = graph.neighbor_at(slot, level, edge_index)
                assert_true(neighbor != slot)
                assert_true(graph.level(neighbor) >= level)
                assert_true(graph.contains_neighbor(neighbor, level, slot))
                for earlier in range(edge_index):
                    assert_true(
                        graph.neighbor_at(slot, level, earlier) != neighbor
                    )


def test_repeated_proposals_are_stored_once_and_bidirectionally() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 2, 3)
    var source = _append(graph, metric, 10, 0.0, 0.0, 1)
    var first = _append(graph, metric, 20, 1.0, 0.0, 1)
    var second = _append(graph, metric, 30, 0.0, 1.0, 1)
    var proposals: List[UInt32] = [first, first, second]
    var stats = HnswBuildStats()

    _connect(graph, metric, source, 0, proposals^, stats)

    assert_equal(graph.neighbor_count(source, 0), 2)
    assert_true(graph.contains_neighbor(source, 0, first))
    assert_true(graph.contains_neighbor(source, 0, second))
    assert_equal(graph.neighbor_count(first, 0), 1)
    assert_equal(graph.neighbor_count(second, 0), 1)
    _assert_symmetric_and_bounded(graph)


def test_full_reverse_adjacency_prunes_both_halves_of_evicted_edge() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 2, 2)
    var center = _append(graph, metric, 10, 0.0, 0.0)
    var nearest = _append(graph, metric, 20, 1.0, 0.0)
    var evicted = _append(graph, metric, 30, 2.0, 0.0)
    var newcomer = _append(graph, metric, 40, 0.5, 0.0)
    var stats = HnswBuildStats()
    var initial: List[UInt32] = [nearest, evicted]
    _connect(graph, metric, center, 0, initial^, stats)
    assert_true(graph.contains_neighbor(evicted, 0, center))

    var proposal: List[UInt32] = [center]
    _connect(graph, metric, newcomer, 0, proposal^, stats)

    assert_equal(graph.neighbor_count(center, 0), 2)
    assert_true(graph.contains_neighbor(center, 0, newcomer))
    assert_true(graph.contains_neighbor(center, 0, nearest))
    assert_false(graph.contains_neighbor(center, 0, evicted))
    assert_false(graph.contains_neighbor(evicted, 0, center))
    assert_true(graph.contains_neighbor(newcomer, 0, center))
    _assert_symmetric_and_bounded(graph)


def test_overflow_pruning_preserves_selected_inactive_traversal_bridge() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 2, 2)
    var center = _append(graph, metric, 10, 0.0, 0.0)
    var evicted = _append(graph, metric, 20, 2.0, 0.0)
    var bridge = _append(graph, metric, 30, -1.0, 0.0)
    var newcomer = _append(graph, metric, 40, 1.0, 0.0)
    var stats = HnswBuildStats()
    var initial: List[UInt32] = [evicted, bridge]
    _connect(graph, metric, center, 0, initial^, stats)
    assert_true(graph.mark_deleted(30))
    assert_false(graph.is_current(bridge))

    var proposal: List[UInt32] = [center]
    _connect(graph, metric, newcomer, 0, proposal^, stats)

    assert_true(graph.is_valid())
    assert_true(graph.contains_neighbor(center, 0, bridge))
    assert_true(graph.contains_neighbor(bridge, 0, center))
    assert_true(graph.contains_neighbor(center, 0, newcomer))
    assert_false(graph.contains_neighbor(center, 0, evicted))
    assert_false(graph.contains_neighbor(evicted, 0, center))
    _assert_symmetric_and_bounded(graph)


def test_upper_levels_use_m_and_require_both_endpoints_to_own_level() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 1, 3)
    var source = _append(graph, metric, 10, 0.0, 0.0, 1)
    var first = _append(graph, metric, 20, 1.0, 0.0, 1)
    var second = _append(graph, metric, 30, 0.5, 0.0, 1)
    var low = _append(graph, metric, 40, 0.25, 0.0, 0)
    var stats = HnswBuildStats()
    var initial: List[UInt32] = [first]
    _connect(graph, metric, source, 1, initial^, stats)
    var replacement: List[UInt32] = [source]
    _connect(graph, metric, second, 1, replacement^, stats)

    assert_equal(graph.neighbor_count(source, 1), 1)
    assert_true(graph.contains_neighbor(source, 1, second))
    assert_false(graph.contains_neighbor(first, 1, source))
    assert_true(graph.contains_neighbor(second, 1, source))

    var invalid: List[UInt32] = [low]
    with assert_raises():
        _connect(graph, metric, source, 1, invalid^, stats)
    assert_true(graph.is_valid())
    _assert_symmetric_and_bounded(graph)


def test_rejected_reciprocal_proposal_preserves_existing_adjacencies() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 2, 2)
    var source = _append(graph, metric, 10, 0.0, 0.0)
    var source_x = _append(graph, metric, 20, 1.0, 0.0)
    var source_y = _append(graph, metric, 30, 0.0, 1.0)
    var target = _append(graph, metric, 40, 0.5, 0.0)
    var target_x = _append(graph, metric, 50, 0.6, 0.0)
    var target_y = _append(graph, metric, 60, 0.5, 0.1)
    var stats = HnswBuildStats()
    var source_initial: List[UInt32] = [source_x, source_y]
    var target_initial: List[UInt32] = [target_x, target_y]
    _connect(graph, metric, source, 0, source_initial^, stats)
    _connect(graph, metric, target, 0, target_initial^, stats)

    var proposal: List[UInt32] = [target]
    _connect(graph, metric, source, 0, proposal^, stats)

    assert_false(graph.contains_neighbor(source, 0, target))
    assert_true(graph.contains_neighbor(source, 0, source_x))
    assert_true(graph.contains_neighbor(source, 0, source_y))
    assert_true(graph.contains_neighbor(target, 0, target_x))
    assert_true(graph.contains_neighbor(target, 0, target_y))
    _assert_symmetric_and_bounded(graph)


def test_validation_detects_asymmetry() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 2, 3)
    var first = _append(graph, metric, 10, 0.0, 0.0)
    var second = _append(graph, metric, 20, 1.0, 0.0)
    var one_way: List[UInt32] = [second]
    graph.set_neighbors(first, 0, one_way^)

    with assert_raises():
        validate_bidirectional_links(graph)


def test_validation_visits_only_owned_levels_in_sparse_high_level_graph() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 1, 1)
    _ = _append(graph, metric, 1, 0.0, 0.0, Int(UInt16.MAX))
    for id in range(2, 34):
        _ = _append(graph, metric, id, Float32(id), 0.0)
    var stats = HnswValidationStats()

    validate_bidirectional_links_with_stats(graph, stats)

    # One 65,536-level slot plus 32 base-only slots. A max-level-by-slot
    # implementation would instead visit more than two million empty cells.
    assert_equal(stats.owned_level_cells, 65_568)
    assert_equal(stats.directed_edges, 0)


def test_prewrite_internal_failure_marks_invalid_and_preserves_stats() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 2, 2)
    var source = _append(graph, metric, 10, 0.0, 0.0)
    var first = _append(graph, metric, 20, 1.0, 0.0)
    var second = _append(graph, metric, 30, 0.0, 1.0)
    var newcomer = _append(graph, metric, 40, -1.0, 0.0)
    var initial: List[UInt32] = [first, second]
    var setup_stats = HnswBuildStats()
    _connect(graph, metric, source, 0, initial^, setup_stats)
    # Corrupt one packed existing edge so endpoint-centered selection raises
    # after public proposal validation but before its first set_neighbors.
    graph.neighbor_slots[graph.neighbor_bases[Int(source)]] = UInt32(99)
    var stats = HnswBuildStats()
    stats.distance_evaluations = 17
    stats.directed_edges = 23
    var proposal: List[UInt32] = [newcomer]

    with assert_raises():
        _connect(graph, metric, source, 0, proposal^, stats)

    assert_false(graph.is_valid())
    assert_equal(stats.distance_evaluations, 17)
    assert_equal(stats.directed_edges, 23)


def test_failed_touched_level_validation_marks_graph_invalid() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var graph = HnswStorage(2, 2, 3)
    var source = _append(graph, metric, 10, 0.0, 0.0)
    var asymmetric = _append(graph, metric, 20, 1.0, 0.0)
    var newcomer = _append(graph, metric, 30, 0.0, 1.0)
    var one_way: List[UInt32] = [asymmetric]
    graph.set_neighbors(source, 0, one_way^)
    var proposal: List[UInt32] = [newcomer]
    var stats = HnswBuildStats()
    stats.distance_evaluations = 29
    stats.directed_edges = 31

    with assert_raises():
        _connect(graph, metric, source, 0, proposal^, stats)

    assert_false(graph.is_valid())
    assert_equal(stats.distance_evaluations, 29)
    assert_equal(stats.directed_edges, 31)
    var raw_query = _vector(0.0, 0.0)
    var query = metric.prepare_query(raw_query^)
    var search_stats = HnswSearchStats()
    with assert_raises():
        _ = greedy_descent(
            graph, metric, query, source, 0, search_stats
        )
    assert_equal(search_stats.distance_evaluations, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
