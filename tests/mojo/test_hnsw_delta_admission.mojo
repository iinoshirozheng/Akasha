from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.bitmap import Bitmap
from akasha.index.flat import authoritative_f32_score
from akasha.index.hnsw_core import HnswEligibility
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.storage.memtable import MemTable
from akasha.compute.topk import BoundedTopK
from test_segmented_hnsw import _lookup
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def exercise(metric: MetricKind) raises:
    for count in [0, 1, 3, 4, 5, 9]:
        for filtered in [False, True]:
            var config = CollectionConfig.defaults(3)
            config.ann_metric = metric.copy()
            config.m = 4
            config.m0 = 8
            var index = SegmentedHnsw(config)
            var table = MemTable(3)
            var query: List[Float32] = [0.25, -0.5, 0.75]
            var expected = BoundedTopK(2, smaller_is_better=Int(metric.tag()) == 1)
            var admitted = 0
            for row in range(count):
                var id = row - 4
                var values: List[Float32] = [Float32(row) / 7, Float32(row % 3) / 5, 1.0]
                index.upsert(id, values)
                table.apply_upsert(id, UInt64(row + 1), values.copy())
                if not filtered or row % 2 == 0:
                    admitted += 1
                    expected.offer(id, authoritative_f32_score(Int(metric.tag()), query, values))
            var lookup = _lookup(table)
            var bitmap = Bitmap(table.slot_count())
            for row in range(count):
                if not filtered or row % 2 == 0:
                    bitmap.set(row)
            var allowed = HnswEligibility(bitmap^, lookup)
            var actual = index.search_allowed(query, 2, 4, 4, allowed, table, lookup) if filtered else index.search(query, 2, 4, table, lookup)
            var oracle = expected.sorted_entries()
            assert_equal(len(actual), len(oracle))
            for i in range(len(actual)):
                assert_equal(actual[i].id, oracle[i].id)
                assert_equal(bitcast[DType.uint32](actual[i].score), bitcast[DType.uint32](oracle[i].score))
            assert_equal(index.last_search_stats().distance_evaluations, 0 if admitted <= 4 else admitted)
            assert_equal(index.last_search_stats().reranked_candidates, min(4, admitted))


def test_dot_delta_skips_preliminary_scores_only_when_all_ids_fit() raises:
    exercise(MetricKind.dot())


def test_l2_delta_skips_preliminary_scores_only_when_all_ids_fit() raises:
    exercise(MetricKind.l2())


def test_cosine_delta_skips_preliminary_scores_only_when_all_ids_fit() raises:
    exercise(MetricKind.cosine())


def test_skipped_preliminary_scores_still_use_and_validate_authority() raises:
    var config = CollectionConfig.defaults(1)
    config.ann_metric = MetricKind.dot()
    var index = SegmentedHnsw(config)
    var table = MemTable(1)
    index.upsert(1, [1.0])
    index.upsert(2, [100.0])
    table.apply_upsert(1, UInt64(1), [200.0])
    table.apply_upsert(2, UInt64(2), [2.0])
    var lookup = _lookup(table)
    var actual = index.search([1.0], 1, 8, table, lookup)
    assert_equal(actual[0].id, 1)
    assert_equal(actual[0].score, Float32(200.0))
    assert_equal(index.last_search_stats().distance_evaluations, 0)
    assert_equal(index.last_search_stats().reranked_candidates, 2)
    table.apply_upsert(2, UInt64(3), [bitcast[DType.float32](UInt32(0x7FC00000))])
    with assert_raises(contains="finite"):
        _ = index.search([1.0], 1, 8, table, lookup)
    var bitmap = Bitmap(2)
    bitmap.set(0)
    var allowed = HnswEligibility(bitmap^, lookup)
    actual = index.search_allowed([1.0], 1, 8, 8, allowed, table, lookup)
    assert_equal(actual[0].id, 1)
    assert_equal(actual[0].score, Float32(200.0))
    assert_equal(index.last_search_stats().distance_evaluations, 0)
    assert_equal(index.last_search_stats().reranked_candidates, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
