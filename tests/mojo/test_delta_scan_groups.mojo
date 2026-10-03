from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswSearchAdmission
from akasha.index.hnsw_heap import HnswHeapItem, ResultMaxHeap
from akasha.index.segmented_hnsw import SegmentedHnsw
from std.memory import bitcast
from std.testing import assert_equal, assert_true, TestSuite


def _check[tag: Int]() raises:
    for dimension in [3, 17, 64, 65, 128, 1536]:
        var config = CollectionConfig.defaults(dimension)
        comptime if tag == 0:
            config.ann_metric = MetricKind.dot()
        elif tag == 1:
            config.ann_metric = MetricKind.l2()
        else:
            config.ann_metric = MetricKind.cosine()
        config.m = 4
        config.m0 = 8
        config.ef_construction = 24
        config.default_ef_search = 16
        config.max_ef_search = 128
        var query = List[Float32](length=dimension, fill=1)
        var base = HnswIndex(config.copy())
        base.add(-100, query.copy())
        var index = SegmentedHnsw.from_owned(base^)
        # Reverse public IDs and repeated rows put ties across group cutoffs.
        for row in range(15):
            var values = List[Float32]()
            for column in range(dimension):
                values.append(Float32(((row // 2) * 17 + column * 19) % 31 - 15) / 17)
            index.upsert(30 - row, values^)
        index.upsert(26, query.copy())
        assert_true(index.delete(20))
        var prepared = index.distance_backend.prepare_query(query)
        var slots = index.delta_slot_count()
        # Counts 0..11 exercise empty, one full group, two groups and every tail.
        for count in range(12):
            var flags = List[Bool](length=slots, fill=False)
            var selected = 0
            var inactive = 0
            var filtered = 0
            var oracle = ResultMaxHeap()
            for position in range(slots):
                var slot = UInt32(position)
                if not index._delta.graph.is_current(slot):
                    inactive += 1
                    continue
                # Rejected current rows interrupt the grouping as well.
                if selected < count and position % 4 != 1:
                    flags[position] = True
                    selected += 1
                    var distance = index._delta.graph._distance_to_slot_backend[tag](
                        index._delta.metric, prepared, slot
                    )
                    oracle.offer(HnswHeapItem(slot, index._delta.graph.id_at(slot), distance), 8)
                else:
                    filtered += 1
            var admission = HnswSearchAdmission(flags^)
            var actual = index._search_delta_prepared_backend[backend_tag=tag](
                prepared, 5, 8, 128, index._sources.delta_count(), admission
            )
            var expected = oracle.take_sorted_best()
            assert_equal(len(actual), len(expected))
            for position in range(len(actual)):
                assert_equal(actual[position].id, expected[position].id)
                assert_equal(
                    bitcast[DType.uint32](actual[position].score),
                    bitcast[DType.uint32](index._delta.metric.public_score(expected[position].distance)),
                )
            ref stats = index._delta.last_search_stats
            assert_equal(stats.storage_name, "delta-scan-f32")
            assert_equal(stats.base_visited, slots)
            assert_equal(stats.inactive_rejections, inactive)
            assert_equal(stats.filtered_rejections, filtered)
            assert_equal(stats.distance_evaluations, selected)
            assert_equal(stats.retained_candidates, len(expected))
            assert_equal(stats.requested_ef, 8)
            assert_equal(stats.effective_ef, 8)
            assert_equal(stats.upper_visited, 0)
            assert_equal(stats.widening_rounds, 0)


def test_dot_delta_scan_groups_keep_scalar_results_and_stats() raises:
    _check[0]()


def test_l2_delta_scan_groups_keep_scalar_results_and_stats() raises:
    _check[1]()


def test_cosine_delta_scan_groups_keep_scalar_results_and_stats() raises:
    _check[2]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
