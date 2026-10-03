from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_core import (
    HnswSearchAdmission,
    greedy_descent,
    search_layer,
    search_prepared_allowed_with_widening_core,
)
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.hnsw_storage import HnswStorage
from std.math import inf, nan
from std.testing import assert_equal, assert_raises, TestSuite


def test_public_layers_validate_numeric_query_before_state_changes() raises:
    for kind in [MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()]:
        var graph = HnswStorage(1, 4, 8, metric_kind=kind)
        _ = graph.append(1, [1.0], 1)
        var metric = MetricDispatcher(kind, ScalarKind.f32(), 1)
        var admission = HnswSearchAdmission()
        var scratch = HnswSearchScratch()
        var stats = HnswSearchStats()
        stats.upper_visited = 19
        stats.base_visited = 17
        stats.distance_evaluations = 23
        var invalid = List[List[Float32]]()
        invalid.append([inf[DType.float32]()])
        invalid.append([nan[DType.float32]()])
        invalid.append([1.0, 0.0])
        if kind == MetricKind.cosine():
            invalid.append([0.0])
            invalid.append([2.0])
        else:
            invalid.append([Float32.MAX_FINITE])
        for query in invalid:
            with assert_raises():
                _ = greedy_descent(graph, metric, query, UInt32(0), 1, stats)
            with assert_raises():
                _ = search_layer(
                    graph, metric, query, UInt32(0), 0, 1, 1,
                    admission, scratch, stats,
                )
            assert_equal(stats.upper_visited, 19)
            assert_equal(stats.base_visited, 17)
            assert_equal(stats.distance_evaluations, 23)
            assert_equal(scratch.epoch, UInt32(0))


def test_widening_core_validates_prepared_query_before_scratch() raises:
    var graph = HnswStorage(1, 4, 8, metric_kind=MetricKind.cosine())
    _ = graph.append(1, [1.0], 1)
    var metric = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 1)
    var admission = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    for value in [
        Float32(0), Float32(2), inf[DType.float32](), nan[DType.float32]()
    ]:
        var query: List[Float32] = [value]
        with assert_raises():
            _ = search_prepared_allowed_with_widening_core(
                graph, metric, query, 1, 1, 1, 1, False, False,
                Optional(UInt32(0)), 1, "owned", admission, scratch,
            )
        assert_equal(scratch.epoch, UInt32(0))
    var outcome = search_prepared_allowed_with_widening_core(
        graph, metric, [1.0], 1, 1, 1, 1, False, False,
        Optional(UInt32(0)), 1, "owned", admission, scratch,
    )
    assert_equal(scratch.epoch, UInt32(1))
    assert_equal(len(outcome.results), 1)
    assert_equal(outcome.results[0].id, 1)
    assert_equal(outcome.results[0].score, Float32(1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
