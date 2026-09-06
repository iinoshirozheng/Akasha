from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.bitmap import Bitmap
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.storage.memtable import MemTable
from std.collections import Dict
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


def _lookup(table: MemTable) raises -> HnswIdOrdinalLookup:
    var ordinals = Dict[Int, Int]()
    for ordinal in range(table.slot_count()):
        ordinals[table.id_at(ordinal)] = ordinal
    return HnswIdOrdinalLookup(ordinals^, table.slot_count())


def _chain_base(config: CollectionConfig, mut table: MemTable) raises -> HnswIndex:
    var index = HnswIndex(config)
    for ordinal in range(4):
        var id = 10 + ordinal
        var values: List[Float32] = [Float32(ordinal)]
        table.apply_upsert(id, UInt64(id), values.copy())
        var level = 1 if ordinal == 0 else 0
        var slot = index.graph.append(id, values^, level)
        if ordinal == 0:
            index.entry_slot = Optional(slot)
            index.entry_level = 1
    index.graph.set_neighbors(UInt32(0), 0, [UInt32(1)])
    index.graph.set_neighbors(UInt32(1), 0, [UInt32(0), UInt32(2)])
    index.graph.set_neighbors(UInt32(2), 0, [UInt32(1), UInt32(3)])
    index.graph.set_neighbors(UInt32(3), 0, [UInt32(2)])
    index.build_stats.slot_count = 4
    index.build_stats.maximum_level = 1
    return index^


def test_base_only_and_delta_only_fast_paths() raises:
    var config = _config()
    var base_table = MemTable(1)
    var base = _base(config.copy(), base_table)
    var base_only = SegmentedHnsw.from_owned(base^)
    var base_lookup = _lookup(base_table)
    var base_result = base_only.search(
        [4.0], 2, 16, base_table, base_lookup
    )
    assert_equal(base_result[0].id, 4)
    assert_equal(base_only.last_search_stats().base_candidates, 4)
    assert_equal(base_only.last_search_stats().delta_candidates, 0)

    var delta_table = MemTable(1)
    var delta_only = SegmentedHnsw(config)
    for id in range(10, 14):
        var values: List[Float32] = [Float32(id)]
        delta_table.apply_upsert(id, UInt64(id), values.copy())
        delta_only.upsert(id, values^)
    var delta_lookup = _lookup(delta_table)
    var delta_result = delta_only.search(
        [13.0], 2, 16, delta_table, delta_lookup
    )
    assert_equal(delta_result[0].id, 13)
    assert_equal(delta_only.last_search_stats().base_candidates, 0)
    assert_equal(delta_only.last_search_stats().delta_candidates, 4)
    assert_equal(base_only.last_candidate_merge_insertions(), 0)
    assert_equal(delta_only.last_candidate_merge_insertions(), 0)


def test_merged_topk_uses_candidates_from_both_sources() raises:
    var config = _config()
    var table = MemTable(1)
    var base = _base(config.copy(), table)
    var index = SegmentedHnsw.from_owned(base^)
    table.apply_upsert(10, UInt64(10), [4.25])
    index.upsert(10, [4.25])

    var lookup = _lookup(table)
    var result = index.search([4.1], 3, 16, table, lookup)
    assert_equal(result[0].id, 4)
    assert_equal(result[1].id, 10)
    assert_equal(result[2].id, 3)
    assert_true(index.last_search_stats().base_candidates > 0)
    assert_true(index.last_search_stats().delta_candidates > 0)
    assert_true(index.last_candidate_merge_insertions() > 0)


def test_replaced_and_deleted_base_ids_are_rejected_after_traversal() raises:
    var config = _config()
    var table = MemTable(1)
    var base = _base(config.copy(), table)
    var index = SegmentedHnsw.from_owned(base^)

    table.apply_upsert(1, UInt64(10), [100.0])
    index.upsert(1, [100.0])
    var lookup = _lookup(table)
    var replaced = index.search([1.0], 1, 16, table, lookup)
    assert_equal(replaced[0].id, 2)

    table.apply_delete(2, UInt64(11))
    assert_true(index.delete(2))
    var deleted = index.search([2.0], 1, 16, table, lookup)
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

    var lookup = _lookup(table)
    var result = index.search([3.0], 4, 16, table, lookup)
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
    var lookup = _lookup(table)
    var result = index.search([2.0], 2, 16, table, lookup)
    assert_equal(result[0].id, 2)
    assert_equal(result[0].score, Float32(0.0))
    assert_equal(result[1].id, 1)
    assert_equal(result[1].score, Float32(324.0))
    assert_equal(index.last_rerank_ordinal_lookups(), 2)
    assert_equal(index.last_rerank_linear_id_scans(), 0)


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
    var lookup = _lookup(table)
    _ = index.search([2.0], 1, 16, table, lookup)
    assert_equal(index.delta_slot_count(), before)
    assert_true(index.needs_rebuild())


def test_filtered_base_only_widens_from_initial_ef_once_per_source() raises:
    var config = _config()
    var table = MemTable(1)
    var base = _chain_base(config.copy(), table)
    var index = SegmentedHnsw.from_owned(base^)
    var lookup = _lookup(table)
    var allowed_bitmap = Bitmap(table.slot_count())
    allowed_bitmap.set(2)
    allowed_bitmap.set(3)
    var allowed = HnswEligibility(allowed_bitmap^, lookup)

    var results = index.search_allowed(
        [0.0], 2, 2, 4, allowed, table, lookup
    )

    assert_equal(len(results), 2)
    assert_equal(results[0].id, 12)
    assert_equal(results[1].id, 13)
    assert_equal(index.last_search_stats().requested_ef, 4)
    assert_equal(index.last_search_stats().effective_ef, 4)
    assert_equal(index.last_search_stats().widening_rounds, 1)
    assert_equal(index.last_search_stats().fallback_reason, "")
    assert_equal(index.last_search_query_preparations(), 1)
    assert_equal(index.last_search_upper_descents(), 1)


def test_filtered_saturation_uses_source_exact_fallback_and_final_stats() raises:
    var config = _config()
    var table = MemTable(1)
    var base = _chain_base(config.copy(), table)
    var index = SegmentedHnsw.from_owned(base^)
    var lookup = _lookup(table)
    var allowed_bitmap = Bitmap(table.slot_count())
    allowed_bitmap.set(2)
    allowed_bitmap.set(3)
    var allowed = HnswEligibility(allowed_bitmap^, lookup)

    var results = index.search_allowed(
        [0.0], 2, 2, 2, allowed, table, lookup
    )

    assert_equal(len(results), 2)
    assert_equal(results[0].id, 12)
    assert_equal(results[1].id, 13)
    assert_equal(index.last_search_stats().requested_ef, 2)
    assert_equal(index.last_search_stats().effective_ef, 2)
    assert_equal(index.last_search_stats().widening_rounds, 0)
    assert_equal(
        index.last_search_stats().fallback_reason,
        "filtered_ann_exhausted",
    )
    assert_equal(index.last_search_query_preparations(), 1)
    assert_equal(index.last_search_upper_descents(), 1)


def test_large_memtable_small_k_reranks_only_bounded_candidates() raises:
    var config = _config()
    config.m = 2
    config.m0 = 2
    var table = MemTable(1)
    var base = HnswIndex(config.copy())
    var count = 512
    for id in range(count):
        var values: List[Float32] = [Float32(id)]
        table.apply_upsert(id, UInt64(id + 1), values.copy())
        var slot = base.graph.append(id, values^, 0)
        if id == 0:
            base.entry_slot = Optional(slot)
            base.entry_level = 0
    for id in range(count):
        var neighbors = List[UInt32]()
        if id > 0:
            neighbors.append(UInt32(id - 1))
        if id + 1 < count:
            neighbors.append(UInt32(id + 1))
        base.graph.set_neighbors(UInt32(id), 0, neighbors^)
    base.build_stats.slot_count = count
    base.build_stats.maximum_level = 0
    base.build_stats.directed_edges = 2 * (count - 1)
    var index = SegmentedHnsw.from_owned(base^)
    var lookup = _lookup(table)

    var results = index.search([0.0], 3, 8, table, lookup)

    assert_equal(len(results), 3)
    assert_equal(results[0].id, 0)
    assert_equal(results[1].id, 1)
    assert_equal(results[2].id, 2)
    assert_equal(index.last_search_stats().reranked_candidates, 8)
    assert_equal(index.last_rerank_ordinal_lookups(), 8)
    assert_equal(index.last_rerank_linear_id_scans(), 0)
    assert_equal(index.last_candidate_merge_insertions(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
