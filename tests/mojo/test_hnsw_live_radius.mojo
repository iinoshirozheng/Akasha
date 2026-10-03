from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_core import (
    HnswSearchAdmission,
    HnswSearchStats,
    greedy_descent,
    search_layer,
)
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_scratch import HnswSearchScratch
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


def _assert_all_true_equivalence(entry_inactive: Bool, replaced: Bool) raises:
    var graph = HnswStorage(1, 4, 8)
    _ = _append(graph, 40, Float32(0.0 if entry_inactive else 3.0))
    _ = _append(graph, 30, Float32(1.0 if entry_inactive else 0.0))
    _ = _append(graph, 20, 2.0)
    _ = _append(graph, 10, 0.5)
    var zero: List[UInt32] = [UInt32(1)]
    var one: List[UInt32] = [UInt32(0), UInt32(2)]
    var two: List[UInt32] = [UInt32(1), UInt32(3)]
    var three: List[UInt32] = [UInt32(2)]
    _set(graph, 0, 0, zero^)
    _set(graph, 1, 0, one^)
    _set(graph, 2, 0, two^)
    _set(graph, 3, 0, three^)
    if entry_inactive:
        assert_true(graph.mark_deleted(40))
    if replaced:
        assert_equal(graph.mark_replaced(30), UInt32(1))
        _ = _append(graph, 30, 100.0)
    else:
        assert_true(graph.mark_deleted(30))
    var flags = List[Bool](length=graph.slot_count(), fill=True)
    var full = HnswSearchAdmission(flags^)
    var plain = HnswSearchAdmission()
    var metric = _metric()
    var query = _query(0.0)
    var scratch = HnswSearchScratch()
    var plain_stats = HnswSearchStats()
    var plain_result = search_layer(
        graph, metric, query, UInt32(0), 0, 1, 1, plain, scratch, plain_stats
    )
    assert_equal(len(plain_result), 1)
    _assert_item(plain_result, 0, 3, 10, 0.25)
    var full_stats = HnswSearchStats()
    var full_result = search_layer(
        graph, metric, query, UInt32(0), 0, 1, 1, full, scratch, full_stats
    )
    assert_equal(len(full_result), 1)
    _assert_item(full_result, 0, 3, 10, 0.25)
    assert_equal(full_stats.base_visited, plain_stats.base_visited)
    assert_equal(full_stats.distance_evaluations, plain_stats.distance_evaluations)
    assert_equal(full_stats.inactive_rejections, plain_stats.inactive_rejections)
    assert_equal(full_stats.filtered_rejections, 0)


def test_deleted_entry_and_bridge_do_not_consume_filtered_radius() raises:
    _assert_all_true_equivalence(True, False)


def test_deleted_middle_does_not_consume_filtered_radius() raises:
    _assert_all_true_equivalence(False, False)


def test_replaced_middle_does_not_consume_filtered_radius() raises:
    _assert_all_true_equivalence(False, True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
