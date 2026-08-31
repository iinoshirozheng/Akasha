from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.storage.memtable import MemTable
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    TestSuite,
)


def _config(*, delta_max_points: Int = 8) -> CollectionConfig:
    var config = CollectionConfig.defaults(1)
    config.ann_metric = MetricKind.l2()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 256
    config.max_level = 4
    config.delta_max_points = delta_max_points
    return config^


def _base(config: CollectionConfig, mut table: MemTable) raises -> HnswIndex:
    var base = HnswIndex(config)
    for id in range(1, 5):
        var values: List[Float32] = [Float32(id)]
        table.apply_upsert(id, UInt64(id), values.copy())
        base.add(id, values^)
    return base^


def test_base_only_and_delta_only_fast_paths() raises:
    var config = _config()
    var base_table = MemTable(1)
    var base = _base(config.copy(), base_table)
    var base_only = SegmentedHnsw.from_owned(base^)
    var base_result = base_only.search([4.0], 2, 16, base_table)
    assert_equal(base_result[0].id, 4)
    assert_equal(base_only.last_search_stats().base_candidates, 4)
    assert_equal(base_only.last_search_stats().delta_candidates, 0)

    var delta_table = MemTable(1)
    var delta_only = SegmentedHnsw(config)
    for id in range(10, 14):
        var values: List[Float32] = [Float32(id)]
        delta_table.apply_upsert(id, UInt64(id), values.copy())
        delta_only.upsert(id, values^)
    var delta_result = delta_only.search([13.0], 2, 16, delta_table)
    assert_equal(delta_result[0].id, 13)
    assert_equal(delta_only.last_search_stats().base_candidates, 0)
    assert_equal(delta_only.last_search_stats().delta_candidates, 4)


def test_merged_topk_uses_candidates_from_both_sources() raises:
    var config = _config()
    var table = MemTable(1)
    var base = _base(config.copy(), table)
    var index = SegmentedHnsw.from_owned(base^)
    table.apply_upsert(10, UInt64(10), [4.25])
    index.upsert(10, [4.25])

    var result = index.search([4.1], 3, 16, table)
    assert_equal(result[0].id, 4)
    assert_equal(result[1].id, 10)
    assert_equal(result[2].id, 3)
    assert_true(index.last_search_stats().base_candidates > 0)
    assert_true(index.last_search_stats().delta_candidates > 0)


def test_replaced_and_deleted_base_ids_are_rejected_after_traversal() raises:
    var config = _config()
    var table = MemTable(1)
    var base = _base(config.copy(), table)
    var index = SegmentedHnsw.from_owned(base^)

    table.apply_upsert(1, UInt64(10), [100.0])
    index.upsert(1, [100.0])
    var replaced = index.search([1.0], 1, 16, table)
    assert_equal(replaced[0].id, 2)

    table.apply_delete(2, UInt64(11))
    assert_true(index.delete(2))
    var deleted = index.search([2.0], 1, 16, table)
    assert_equal(deleted[0].id, 3)


def test_delta_delete_reinsert_and_candidate_deduplication() raises:
    var config = _config()
    var table = MemTable(1)
    var base = HnswIndex(config.copy())
    table.apply_upsert(7, UInt64(1), [1.0])
    base.add(7, [1.0])
    var index = SegmentedHnsw.from_owned(base^)

    table.apply_upsert(7, UInt64(2), [2.0])
    index.upsert(7, [2.0])
    table.apply_delete(7, UInt64(3))
    assert_true(index.delete(7))
    table.apply_upsert(7, UInt64(4), [3.0])
    index.upsert(7, [3.0])

    var result = index.search([3.0], 4, 16, table)
    assert_equal(len(result), 1)
    assert_equal(result[0].id, 7)
    assert_equal(result[0].score, Float32(0.0))
    assert_equal(index.last_search_stats().reranked_candidates, 1)


def test_exact_rerank_reads_authoritative_memtable_vectors() raises:
    var config = _config()
    var table = MemTable(1)
    var base = HnswIndex(config.copy())
    table.apply_upsert(1, UInt64(1), [1.0])
    table.apply_upsert(2, UInt64(2), [2.0])
    base.add(1, [1.0])
    base.add(2, [2.0])
    var index = SegmentedHnsw.from_owned(base^)

    # The graph supplies IDs only; authoritative exact scoring comes from the
    # current MemTable vector.
    table.apply_upsert(1, UInt64(3), [20.0])
    var result = index.search([2.0], 2, 16, table)
    assert_equal(result[0].id, 2)
    assert_equal(result[0].score, Float32(0.0))
    assert_equal(result[1].id, 1)
    assert_equal(result[1].score, Float32(324.0))


def test_delta_threshold_latches_without_query_time_rebuild() raises:
    var config = _config(delta_max_points=2)
    var table = MemTable(1)
    var index = SegmentedHnsw(config)
    table.apply_upsert(1, UInt64(1), [1.0])
    index.upsert(1, [1.0])
    assert_false(index.needs_rebuild())
    table.apply_upsert(2, UInt64(2), [2.0])
    index.upsert(2, [2.0])
    assert_true(index.needs_rebuild())
    var before = index.delta_slot_count()
    _ = index.search([2.0], 1, 16, table)
    assert_equal(index.delta_slot_count(), before)
    assert_true(index.needs_rebuild())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
