from akasha.index.hnsw_entries import HnswEntry
from akasha.index.hnsw_query_scorer import MetricPointScorer
from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswSearchAdmission
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_stats import HnswSearchStats
from qdrant_search_reference import (
    choose_entry,
    score_points,
    search,
    search_level,
)
from std.testing import assert_equal, assert_raises, TestSuite


def _fixture(level: Int = 0) raises -> HnswIndex:
    var config = CollectionConfig.defaults(1)
    config.ann_metric = MetricKind.l2()
    config.m = 4
    config.m0 = 4
    var index = HnswIndex(config)
    for i in range(3):
        var vector: List[Float32] = [Float32(3 - i)]
        _ = index.graph.append(100 + i, vector^, level)
    var a: List[UInt32] = [UInt32(1), UInt32(2)]
    var b: List[UInt32] = [UInt32(0), UInt32(2)]
    var c: List[UInt32] = [UInt32(0), UInt32(1)]
    for graph_level in range(level + 1):
        index.graph.set_neighbors(UInt32(0), graph_level, a)
        index.graph.set_neighbors(UInt32(1), graph_level, b)
        index.graph.set_neighbors(UInt32(2), graph_level, c)
    return index^


def test_rejected_neighbor_is_not_scored() raises:
    var index = _fixture()
    var flags: List[Bool] = [True, False, True]
    var allowed = HnswSearchAdmission(flags^)
    var query: List[Float32] = [0.0]
    var stats = HnswSearchStats()
    var result = search_level(
        index.graph,
        MetricPointScorer(index.metric, query^),
        HnswHeapItem(UInt32(0), 100, 9.0),
        0,
        3,
        allowed,
        index.scratch,
        stats,
    )
    assert_equal(len(result), 2)
    assert_equal(result[0].id, 102)
    # Entry arrives already scored, exactly as in GraphLayers::search_on_level.
    assert_equal(stats.distance_evaluations, 1)
    assert_equal(stats.filtered_rejections, 2)
    assert_equal(index.scratch.visited_epochs[1] != index.scratch.epoch, True)


def test_filtering_precedes_batch_limit() raises:
    var index = _fixture()
    var flags: List[Bool] = [True, False, True]
    var allowed = HnswSearchAdmission(flags^)
    var query: List[Float32] = [0.0]
    var points: List[UInt32] = [UInt32(1), UInt32(2), UInt32(0)]
    var stats = HnswSearchStats()
    var scored = List[HnswHeapItem](capacity=3)
    var scorer = MetricPointScorer(index.metric, query^)
    var address = Int(scored.unsafe_ptr())
    score_points(
        index.graph, scorer, points, 1, allowed, stats, scored
    )
    assert_equal(len(scored), 1)
    assert_equal(scored[0].id, 102)
    assert_equal(stats.distance_evaluations, 1)
    assert_equal(stats.filtered_rejections, 1)
    assert_equal(len(points), 1)
    assert_equal(points[0], UInt32(2))
    points.clear()
    points.append(UInt32(1))
    score_points(
        index.graph, scorer, points, 0, allowed, stats, scored
    )
    assert_equal(len(points), 0)
    assert_equal(len(scored), 0)
    assert_equal(Int(scored.unsafe_ptr()), address)
    points.append(UInt32(0))
    points.append(UInt32(2))
    score_points(
        index.graph, scorer, points, 0, allowed, stats, scored
    )
    assert_equal(len(scored), 2)
    assert_equal(Int(scored.unsafe_ptr()), address)


def test_entry_pool_uses_first_eligible_primary_then_highest_extra() raises:
    var index = _fixture(1)
    var vector: List[Float32] = [0.5]
    var higher = index.graph.append(103, vector^, 2)
    var primary: List[HnswEntry] = [HnswEntry(UInt32(0), 0), HnswEntry(higher, 2)]
    var extra: List[HnswEntry] = [HnswEntry(UInt32(1), 0), HnswEntry(higher, 2), HnswEntry(UInt32(2), 0)]
    var all_allowed = HnswSearchAdmission()
    assert_equal(
        choose_entry(index.graph, primary, extra, all_allowed).value().slot,
        UInt32(0),
    )
    var empty = List[HnswEntry]()
    assert_equal(
        choose_entry(index.graph, empty, extra, all_allowed).value().slot, higher
    )
    var flags: List[Bool] = [False, False, True, False]
    var allowed = HnswSearchAdmission(flags^)
    assert_equal(
        choose_entry(index.graph, primary, extra, allowed).value().slot, UInt32(2)
    )


def test_missing_eligible_entry_does_not_scan_graph_or_exact_fallback() raises:
    var index = _fixture()
    var flags: List[Bool] = [False, False, True]
    var allowed = HnswSearchAdmission(flags^)
    var query: List[Float32] = [0.0]
    var primary: List[HnswEntry] = [HnswEntry(UInt32(0), 0)]
    var extra: List[HnswEntry] = [HnswEntry(UInt32(1), 0)]
    var stats = HnswSearchStats()
    var result = search(
        index.graph,
        index.metric,
        query,
        primary,
        extra,
        1,
        3,
        allowed,
        index.scratch,
        stats,
    )
    assert_equal(len(result), 0)
    assert_equal(stats.distance_evaluations, 0)


def test_filtered_upper_descent_reuses_level_zero_entry_score() raises:
    var index = _fixture(1)
    var flags: List[Bool] = [True, False, True]
    var allowed = HnswSearchAdmission(flags^)
    var query: List[Float32] = [0.0]
    var primary: List[HnswEntry] = [HnswEntry(UInt32(0), 1)]
    var extra = List[HnswEntry]()
    var stats = HnswSearchStats()
    var result = search(
        index.graph,
        index.metric,
        query,
        primary,
        extra,
        1,
        3,
        allowed,
        index.scratch,
        stats,
    )
    assert_equal(len(result), 1)
    assert_equal(result[0].id, 102)
    assert_equal(stats.upper_visited, 3)
    # Upper: entry 0, neighbor 2, neighbor 0 again. Lower: neighbor 0 only.
    assert_equal(stats.distance_evaluations, 4)


def test_rejected_bridge_requires_graph_construction_support() raises:
    var index = _fixture()
    var left: List[UInt32] = [UInt32(1)]
    var middle: List[UInt32] = [UInt32(0), UInt32(2)]
    var right: List[UInt32] = [UInt32(1)]
    index.graph.set_neighbors(UInt32(0), 0, left)
    index.graph.set_neighbors(UInt32(1), 0, middle)
    index.graph.set_neighbors(UInt32(2), 0, right)
    var flags: List[Bool] = [True, False, True]
    var allowed = HnswSearchAdmission(flags^)
    var query: List[Float32] = [0.0]
    var primary: List[HnswEntry] = [HnswEntry(UInt32(0), 0)]
    var extra = List[HnswEntry]()
    var stats = HnswSearchStats()
    var result = search(
        index.graph,
        index.metric,
        query,
        primary,
        extra,
        1,
        3,
        allowed,
        index.scratch,
        stats,
    )
    assert_equal(result[0].id, 100)
    assert_equal(stats.distance_evaluations, 1)
    # A filter-aware construction edge makes the eligible subgraph searchable.
    var direct: List[UInt32] = [UInt32(1), UInt32(2)]
    index.graph.set_neighbors(UInt32(0), 0, direct)
    var supported = search(
        index.graph,
        index.metric,
        query,
        primary,
        extra,
        1,
        3,
        allowed,
        index.scratch,
        stats,
    )
    assert_equal(supported[0].id, 102)


def test_evicted_frontier_candidate_cannot_expand_beyond_bound() raises:
    var index = _fixture()
    var vector: List[Float32] = [0.0]
    _ = index.graph.append(103, vector^, 0)
    var middle: List[UInt32] = [UInt32(0), UInt32(2), UInt32(3)]
    var tail: List[UInt32] = [UInt32(1)]
    index.graph.set_neighbors(UInt32(1), 0, middle)
    index.graph.set_neighbors(UInt32(3), 0, tail)
    var query: List[Float32] = [0.0]
    var primary: List[HnswEntry] = [HnswEntry(UInt32(0), 0)]
    var extra = List[HnswEntry]()
    var allowed = HnswSearchAdmission()
    var stats = HnswSearchStats()
    var result = search(
        index.graph,
        index.metric,
        query,
        primary,
        extra,
        1,
        1,
        allowed,
        index.scratch,
        stats,
    )
    assert_equal(result[0].id, 102)
    assert_equal(stats.distance_evaluations, 3)
    assert_equal(index.scratch.visited_epochs[3] != index.scratch.epoch, True)


def test_akasha_tie_order_is_explicitly_preserved() raises:
    var index = _fixture()
    index.graph.vector_scalars[0] = 1.0
    index.graph.vector_scalars[1] = 1.0
    var query: List[Float32] = [0.0]
    var primary: List[HnswEntry] = [HnswEntry(UInt32(2), 0)]
    var extra = List[HnswEntry]()
    var allowed = HnswSearchAdmission()
    var stats = HnswSearchStats()
    var result = search(
        index.graph,
        index.metric,
        query,
        primary,
        extra,
        1,
        3,
        allowed,
        index.scratch,
        stats,
    )
    assert_equal(result[0].id, 100)


def test_zero_k_and_negative_limits() raises:
    var index = _fixture()
    var query: List[Float32] = [0.0]
    var primary: List[HnswEntry] = [HnswEntry(UInt32(0), 0)]
    var extra = List[HnswEntry]()
    var allowed = HnswSearchAdmission()
    var stats = HnswSearchStats()
    var result = search(
        index.graph,
        index.metric,
        query,
        primary,
        extra,
        0,
        0,
        allowed,
        index.scratch,
        stats,
    )
    assert_equal(len(result), 0)
    with assert_raises():
        _ = search(
            index.graph,
            index.metric,
            query,
            primary,
            extra,
            -1,
            3,
            allowed,
            index.scratch,
            stats,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
