from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_core import HnswSearchAdmission, HnswSearchStats, search_layer
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_storage import HnswStorage
from std.testing import assert_equal, assert_true, TestSuite


def test_full_group_tail_and_revisited_filtered_bridges_keep_order() raises:
    var graph = HnswStorage(1, 4, 8)
    var values: List[Float32] = [10, 8, 6, 4, 2, -2, 2, 0, 1, -1]
    for slot in range(len(values)):
        var vector: List[Float32] = [values[slot]]
        _ = graph.append(90 - slot * 10, vector^, 0)
    var root: List[UInt32] = [1, 2, 3, 4, 5, 6, 7]
    graph.set_neighbors(UInt32(0), 0, root)
    var left: List[UInt32] = [0, 6, 8]
    graph.set_neighbors(UInt32(4), 0, left)
    var right: List[UInt32] = [0, 4, 9]
    graph.set_neighbors(UInt32(6), 0, right)
    assert_true(graph.mark_deleted(70))
    var flags: List[Bool] = [True, False, True, True, True, False, True, True, True, True]
    var admission = HnswSearchAdmission(flags^)
    var metric = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 1)
    var query: List[Float32] = [0]
    var scratch = HnswSearchScratch()
    for _ in range(2):
        var stats = HnswSearchStats()
        var actual = search_layer[backend_tag=1](
            graph, metric, query, UInt32(0), 0, 3, 4, admission, scratch, stats
        )
        assert_equal(len(actual), 3)
        assert_equal(actual[0].id, 20)
        assert_equal(actual[0].distance, Float32(0))
        assert_equal(actual[1].id, 0)
        assert_equal(actual[1].distance, Float32(1))
        assert_equal(actual[2].id, 10)
        assert_equal(actual[2].distance, Float32(1))
        assert_equal(stats.base_visited, 10)
        assert_equal(stats.distance_evaluations, 10)
        assert_equal(stats.filtered_rejections, 2)
        assert_equal(stats.inactive_rejections, 1)
        assert_equal(stats.retained_candidates, 3)
    assert_equal(scratch.epoch, UInt32(2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
