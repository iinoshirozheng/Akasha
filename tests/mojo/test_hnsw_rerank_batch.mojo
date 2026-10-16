from akasha.common.config import CollectionConfig, MetricKind
from akasha.compute.topk import BoundedTopK
from akasha.index.bitmap import Bitmap
from akasha.index.flat import authoritative_f32_score
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswEligibility
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.storage.memtable import MemTable
from test_segmented_hnsw import _lookup
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def exercise(metric: MetricKind) raises:
    for dimension in [1, 3, 15, 16, 17, 63, 64, 65, 128, 1536]:
        var config = CollectionConfig.defaults(dimension)
        config.ann_metric = metric.copy()
        config.m = 4
        config.m0 = 8
        var base = HnswIndex(config.copy())
        var table = MemTable(dimension)
        for row in range(9):
            var values = List[Float32]()
            var graph_values = List[Float32]()
            for column in range(dimension):
                values.append(Float32((row * 7 + column * 11) % 29 - 14) / 17)
                graph_values.append(Float32((row * 3 + column * 5) % 17 - 8) / 13)
            # Graph values deliberately differ: all scores must use authority.
            base.add(row - 5, graph_values^)
            table.apply_upsert(row - 5, UInt64(row + 1), values^)
        var index = SegmentedHnsw.from_owned(base^)
        var lookup = _lookup(table)
        var bitmap = Bitmap(table.slot_count())
        for ordinal in range(table.slot_count()):
            bitmap.set(ordinal)
        var allowed = HnswEligibility(bitmap^, lookup)
        var query = List[Float32]()
        for column in range(dimension):
            query.append(Float32((column * 17 + 3) % 37 - 18) / 19)
        for count in range(10):
            var candidates = List[Int]()
            for row in range(count):
                candidates.append((row * 5) % 9 - 5)
            for requested in [0, 1, 3, 9]:
                var target = min(count, requested)
                var expected = BoundedTopK(max(1, target), smaller_is_better=Int(metric.tag()) == 1)
                if target > 0:
                    for id in candidates:
                        expected.offer(id, authoritative_f32_score(
                            Int(metric.tag()), query, table.entry_ref_at(lookup.ordinal_for(id)).values()
                        ))
                var entries = expected.sorted_entries()
                for filtered in [False, True]:
                    var results = index._rerank_allowed_candidates(
                        query, target, candidates, table, lookup, allowed
                    ) if filtered else index._rerank_candidates(
                        query, target, candidates, table, lookup
                    )
                    assert_equal(len(results), len(entries))
                    for i in range(len(results)):
                        assert_equal(results[i].id, entries[i].id)
                        assert_equal(bitcast[DType.uint32](results[i].score), bitcast[DType.uint32](entries[i].score))
                    assert_equal(index.last_rerank_ordinal_lookups(), count if target > 0 else 0)
                    assert_equal(index.last_search_stats().reranked_candidates, count if target > 0 else 0)
                    assert_equal(index.last_rerank_linear_id_scans(), 0)


def test_dot_rerank_keeps_authoritative_bits_for_pairs_and_tails() raises:
    exercise(MetricKind.dot())


def test_l2_rerank_keeps_authoritative_bits_for_pairs_and_tails() raises:
    exercise(MetricKind.l2())


def test_cosine_rerank_keeps_authoritative_bits_for_pairs_and_tails() raises:
    exercise(MetricKind.cosine())


def test_rerank_rejects_invalid_second_candidate_and_filter() raises:
    var config = CollectionConfig.defaults(1)
    var base = HnswIndex(config.copy())
    var table = MemTable(1)
    for id in range(2):
        base.add(id, [Float32(id)])
        table.apply_upsert(id, UInt64(id + 1), [Float32(id)])
    var index = SegmentedHnsw.from_owned(base^)
    var lookup = _lookup(table)
    var bitmap = Bitmap(2)
    bitmap.set(0)
    var allowed = HnswEligibility(bitmap^, lookup)
    with assert_raises(contains="filter eligible"):
        _ = index._rerank_allowed_candidates([1.0], 1, [0, 1], table, lookup, allowed)
    table.apply_delete(1, UInt64(3))
    with assert_raises():
        _ = index._rerank_candidates([1.0], 1, [0, 1], table, lookup)
    with assert_raises():
        _ = index._rerank_candidates([1.0], 1, [0, 999], table, lookup)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
