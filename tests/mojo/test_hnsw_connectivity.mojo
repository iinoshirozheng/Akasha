from akasha.index.hnsw_connectivity import HnswBuildRandom, subgraph_connectivity
from akasha.index.hnsw_entries import HnswEntry, HnswEntryPoints
from akasha.index.hnsw_storage import HnswStorage
from std.testing import assert_equal, TestSuite


def test_connectivity_carries_upper_visits_down_and_filters_points() raises:
    var graph = HnswStorage(1, 2, 4)
    _ = graph.append(0, [0.0], 1)
    _ = graph.append(1, [1.0], 1)
    _ = graph.append(2, [2.0], 0)
    # Point 0: empty base, upper -> 1; point 1: base -> 2, empty upper.
    var rows: List[List[UInt32]] = [[], [UInt32(1)], [UInt32(2)], [], []]
    var entries = HnswEntryPoints()
    entries.primary.append(HnswEntry(UInt32(0), 0))
    var rng = HnswBuildRandom(42)
    var points: List[UInt32] = [UInt32(0), UInt32(1), UInt32(2)]
    assert_equal(subgraph_connectivity(graph, entries, rows, points, 0, rng), Float32(1))
    assert_equal(subgraph_connectivity(graph, entries, rows, points, 1, rng), Float32(1) / 3)
    var filtered: List[UInt32] = [UInt32(0), UInt32(2)]
    assert_equal(subgraph_connectivity(graph, entries, rows, filtered, 0, rng), Float32(0.5))


def test_empty_and_edgeless_graphs_terminate_without_spending_budget() raises:
    var graph = HnswStorage(1, 2, 4)
    var rows = List[List[UInt32]]()
    var entries = HnswEntryPoints()
    var points = List[UInt32]()
    var rng = HnswBuildRandom(7)
    assert_equal(subgraph_connectivity(graph, entries, rows, points, 0.5, rng), Float32(1))
    assert_equal(rng.state, UInt64(7))
    for id in range(3):
        points.append(graph.append(id, [Float32(id)], 0))
        rows.append(List[UInt32]())
    assert_equal(subgraph_connectivity(graph, entries, rows, points, 0.5, rng), Float32(1) / 3)
    # No eligible entries: the highest-level fallback does not draw randomness.
    assert_equal(rng.state, UInt64(7))


def test_retries_keep_total_budget_but_reset_reached_points() raises:
    var graph = HnswStorage(1, 2, 4)
    _ = graph.append(0, [0.0], 0)
    _ = graph.append(1, [1.0], 0)
    var rows: List[List[UInt32]] = [[UInt32(1)], []]
    var entries = HnswEntryPoints()
    entries.primary.append(HnswEntry(UInt32(0), 0))
    var points: List[UInt32] = [UInt32(0), UInt32(1)]
    var rng = HnswBuildRandom(42)
    assert_equal(subgraph_connectivity(graph, entries, rows, points, 0, rng), Float32(1))
    var expected = HnswBuildRandom(42)
    _ = expected.index(1)
    for _ in range(65):
        _ = expected.coin()
    assert_equal(rng.state, expected.state)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
