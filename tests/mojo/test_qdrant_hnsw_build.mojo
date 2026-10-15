"""Construction semantics from Qdrant 21db2f3 LinksContainer/GraphLayersBuilder."""

from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_core import connect_with_heuristic
from akasha.index.hnsw_stats import HnswBuildStats
from akasha.index.hnsw_storage import HnswStorage
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def test_backlink_pruning_does_not_delete_independent_outgoing_edges() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 1)
    var graph = HnswStorage(1, 2, 2)
    var center = graph.append(10, [0.0], 0)
    var first = graph.append(20, [1.0], 0)
    var second = graph.append(30, [2.0], 0)
    var newcomer = graph.append(40, [0.5], 0)
    graph.set_neighbors(center, 0, [first, second])
    graph.set_neighbors(first, 0, [center])
    graph.set_neighbors(second, 0, [center])
    var stats = HnswBuildStats()
    stats.directed_edges = 4
    connect_with_heuristic(graph, metric, newcomer, 0, [center], stats)
    assert_equal(graph.neighbor_count(center, 0), 1)
    assert_true(graph.contains_neighbor(center, 0, newcomer))
    assert_false(graph.contains_neighbor(center, 0, first))
    assert_false(graph.contains_neighbor(center, 0, second))
    assert_true(graph.contains_neighbor(first, 0, center))
    assert_true(graph.contains_neighbor(second, 0, center))
    assert_true(graph.contains_neighbor(newcomer, 0, center))
    assert_equal(stats.directed_edges, 4)


def test_rejected_backlink_keeps_selected_outgoing_edge() raises:
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 1)
    var graph = HnswStorage(1, 1, 1)
    var center = graph.append(10, [0.0], 0)
    var first = graph.append(20, [1.0], 0)
    var newcomer = graph.append(30, [2.0], 0)
    graph.set_neighbors(center, 0, [first])
    graph.set_neighbors(first, 0, [center])
    var stats = HnswBuildStats()
    stats.directed_edges = 2
    connect_with_heuristic(graph, metric, newcomer, 0, [center], stats)
    assert_true(graph.contains_neighbor(newcomer, 0, center))
    assert_false(graph.contains_neighbor(center, 0, newcomer))
    assert_equal(stats.directed_edges, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
