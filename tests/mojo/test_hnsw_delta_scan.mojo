from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.topk import BoundedTopK
from akasha.index.bitmap import Bitmap
from akasha.index.flat import authoritative_f32_score
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup
from akasha.index.segmented_hnsw import SegmentedHnsw, _should_scan_delta
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import (
    encode_hnsw_snapshot,
    open_hnsw_snapshot_view,
)
from akasha.storage.memtable import MemTable
from std.collections import Dict
from std.memory import bitcast
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _config(metric: MetricKind, scalar: ScalarKind) -> CollectionConfig:
    var config = CollectionConfig.defaults(3)
    config.ann_metric = metric.copy()
    config.scalar_kind = scalar.copy()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 128
    config.max_level = 4
    return config^


def _lookup(table: MemTable) raises -> HnswIdOrdinalLookup:
    var ordinals = Dict[Int, Int]()
    for ordinal in range(table.slot_count()):
        ordinals[table.id_at(ordinal)] = ordinal
    return HnswIdOrdinalLookup(ordinals^, table.slot_count())


def _check_native_case(
    metric: MetricKind, scalar: ScalarKind, mapped: Bool
) raises:
    var config = _config(metric, scalar)
    var table = MemTable(3)
    var base = HnswIndex(config.copy())
    for id in range(1, 7):
        var values: List[Float32] = [Float32(id), 1.0, -1.0]
        table.apply_upsert(id, UInt64(id), values.copy())
        base.add(id, values^)
    var path = String("/tmp/akasha-delta-scan-native.bin")
    remove_file_if_exists(path)
    var index: SegmentedHnsw
    if mapped:
        write_file_sync(path, encode_hnsw_snapshot(base, UInt64(6)))
        index = SegmentedHnsw.from_mapped(
            open_hnsw_snapshot_view(path, config, UInt64(6))
        )
    else:
        index = SegmentedHnsw.from_owned(base^)
    for id in range(4, 11):
        var values: List[Float32] = [Float32(id), -1.0, 1.0]
        table.apply_upsert(id, UInt64(10 + id), values.copy())
        index.upsert(id, values^)
    # Replacement, deletion and reinsertion leave historical physical slots.
    table.apply_upsert(7, UInt64(30), [2.0, -1.0, 1.0])
    index.upsert(7, [2.0, -1.0, 1.0])
    table.apply_delete(8, UInt64(31))
    assert_true(index.delete(8))
    table.apply_delete(9, UInt64(32))
    assert_true(index.delete(9))
    table.apply_upsert(9, UInt64(33), [2.0, -1.0, 1.0])
    index.upsert(9, [2.0, -1.0, 1.0])
    var lookup = _lookup(table)
    var query: List[Float32] = [2.0, -1.0, 1.0]
    for filtered in [False, True]:
        var bitmap = Bitmap(table.slot_count())
        var expected = BoundedTopK(
            10, smaller_is_better=metric == MetricKind.l2()
        )
        var admitted_delta = 0
        for ordinal in range(table.slot_count()):
            var id = table.id_at(ordinal)
            if table.is_live_at(ordinal) and (not filtered or id % 2 == 1):
                bitmap.set(ordinal)
                ref entry = table.entry_ref_at(ordinal)
                expected.offer(
                    id,
                    authoritative_f32_score(
                        Int(metric.tag()), query, entry.values()
                    ),
                )
                if id >= 4:
                    admitted_delta += 1
        var allowed = HnswEligibility(bitmap^, lookup)
        var actual = index.search(query, 10, 16, table, lookup)
        if filtered:
            actual = index.search_allowed(
                query, 10, 16, 128, allowed, table, lookup
            )
        var oracle = expected.sorted_entries()
        assert_equal(len(actual), len(oracle))
        for position in range(len(actual)):
            assert_equal(actual[position].id, oracle[position].id)
            assert_equal(actual[position].score, oracle[position].score)
        assert_equal(
            index.last_search_stats().storage_name,
            String("segmented-delta-scan-", config.scalar_name()),
        )
        assert_equal(
            index._delta.last_search_stats.distance_evaluations, admitted_delta
        )
        assert_equal(
            index._delta.last_search_stats.base_visited,
            index.delta_slot_count(),
        )
        assert_equal(index._delta.last_search_stats.upper_visited, 0)
        assert_equal(index._delta.last_search_upper_descents(), 0)
        assert_equal(index._delta.last_search_stats.inactive_rejections, 3)
        assert_equal(index.last_search_query_preparations(), 1)
        assert_equal(index.last_search_stats().fallback_reason, "")
        # Exercise a heap cutoff in every native backend, including filtered
        # admission. The fixture has well-separated scores and exact ties.
        actual = index.search(query, 2, 2, table, lookup)
        if filtered:
            actual = index.search_allowed(
                query, 2, 2, 128, allowed, table, lookup
            )
        assert_equal(len(actual), 2)
        for position in range(2):
            assert_equal(actual[position].id, oracle[position].id)
            assert_equal(actual[position].score, oracle[position].score)
        assert_equal(index._delta.last_search_stats.retained_candidates, 2)
        assert_equal(index._delta.last_search_stats.effective_ef, 2)
    var empty = HnswEligibility(Bitmap(table.slot_count()), lookup)
    var no_results = index.search_allowed(
        query, 2, 16, 128, empty, table, lookup
    )
    assert_equal(len(no_results), 0)
    assert_equal(index._delta.last_search_stats.distance_evaluations, 0)
    index.close()
    remove_file_if_exists(path)


def test_owned_and_mapped_delta_scan_native_backends() raises:
    var scalars: List[ScalarKind] = [
        ScalarKind.f32(),
        ScalarKind.f16(),
        ScalarKind.bf16(),
        ScalarKind.i8(),
    ]
    var metrics: List[MetricKind] = [
        MetricKind.dot(),
        MetricKind.l2(),
        MetricKind.cosine(),
    ]
    for scalar in scalars:
        for metric in metrics:
            if scalar == ScalarKind.i8() and metric == MetricKind.l2():
                continue
            for mapped in [False, True]:
                _check_native_case(metric, scalar, mapped)


def test_scan_preserves_invalid_query_identity_and_demand_checks() raises:
    var config = _config(MetricKind.l2(), ScalarKind.f32())
    var base = HnswIndex(config.copy())
    var table = MemTable(3)
    base.add(1, [1.0, 0.0, 0.0])
    table.apply_upsert(1, UInt64(1), [1.0, 0.0, 0.0])
    var index = SegmentedHnsw.from_owned(base^)
    for id in range(2, 6):
        index.upsert(id, [Float32(id), 0.0, 0.0])
        table.apply_upsert(id, UInt64(id), [Float32(id), 0.0, 0.0])
    var lookup = _lookup(table)
    var query: List[Float32] = [1.0, 0.0, 0.0]
    _ = index.search(query, 1, 16, table, lookup)
    assert_equal(
        index.last_search_stats().storage_name, "segmented-delta-scan-f32"
    )
    with assert_raises():
        _ = index.search([1.0], 1, 16, table, lookup)
    with assert_raises():
        _ = index.search(
            [bitcast[DType.float32](UInt32(0x7FC00000)), 0.0, 0.0],
            1,
            16,
            table,
            lookup,
        )
    with assert_raises():
        _ = index.search(query, 0, 16, table, lookup)
    with assert_raises():
        _ = index.search(query, 1, 129, table, lookup)
    var bitmap = Bitmap(table.slot_count())
    for ordinal in range(table.slot_count()):
        bitmap.set(ordinal)
    var allowed = HnswEligibility(bitmap^, lookup)
    with assert_raises():
        _ = index.search_allowed(query, 4, 1, 2, allowed, table, lookup)
    index._delta.config.m0 += 1
    with assert_raises():
        _ = index.search(query, 1, 16, table, lookup)
    index._delta.config.m0 -= 1
    index._delta.graph.mark_invalid()
    with assert_raises():
        _ = index.search(query, 1, 16, table, lookup)


def test_delta_scan_work_bounds_and_integer_extremes() raises:
    assert_true(_should_scan_delta(1, 1024, 1024, 1536, 48, 32))
    assert_true(_should_scan_delta(1, 1024, 1024, 1536, 48, 22))
    assert_false(_should_scan_delta(1, 1024, 1024, 1536, 48, 21))
    assert_false(_should_scan_delta(1, 1024, 1024, 1536, 48, 10))
    assert_false(_should_scan_delta(1, 4096, 4096, 1536, 48, 32))
    assert_false(_should_scan_delta(1, 1025, 1025, 1, 48, 128))
    assert_false(_should_scan_delta(1, 1024, 1024, 1537, 48, 128))
    assert_false(_should_scan_delta(0, 64, 64, 3, 48, 32))
    assert_true(_should_scan_delta(Int.MAX, 1024, 1024, 1, Int.MAX, Int.MAX))
    for bad in [0, -1, Int.MIN]:
        assert_false(_should_scan_delta(bad, 64, 64, 3, 48, 32))
        assert_false(_should_scan_delta(1, bad, bad, 3, 48, 32))
        assert_false(_should_scan_delta(1, 64, 64, bad, 48, 32))
        assert_false(_should_scan_delta(1, 64, 64, 3, bad, 32))
        assert_false(_should_scan_delta(1, 64, 64, 3, 48, bad))
    assert_false(_should_scan_delta(1, Int.MAX, Int.MAX, 1, 48, Int.MAX))
    assert_false(_should_scan_delta(1, 1, 1, Int.MAX, 48, Int.MAX))


def test_physical_history_controls_scan_and_single_source_stays_graph() raises:
    var config = _config(MetricKind.l2(), ScalarKind.f32())
    var base = HnswIndex(config.copy())
    var table = MemTable(3)
    base.add(1, [100.0, 0.0, 0.0])
    table.apply_upsert(1, UInt64(1), [100.0, 0.0, 0.0])
    var index = SegmentedHnsw.from_owned(base^)
    for revision in range(8):
        index.upsert(2, [Float32(revision), 0.0, 0.0])
        table.apply_upsert(
            2, UInt64(revision + 2), [Float32(revision), 0.0, 0.0]
        )
    var lookup = _lookup(table)
    _ = index.search([7.0, 0.0, 0.0], 1, 1, table, lookup)
    assert_equal(
        index.last_search_stats().storage_name, "segmented-delta-scan-f32"
    )
    assert_equal(index._delta.last_search_stats.inactive_rejections, 7)
    assert_equal(index._delta.last_search_stats.distance_evaluations, 1)
    index.upsert(2, [8.0, 0.0, 0.0])
    table.apply_upsert(2, UInt64(10), [8.0, 0.0, 0.0])
    var result = index.search([8.0, 0.0, 0.0], 1, 1, table, lookup)
    assert_equal(result[0].id, 2)
    assert_equal(index.last_search_stats().storage_name, "segmented-f32")
    _ = index.search([8.0, 0.0, 0.0], 1, 2, table, lookup)
    assert_equal(
        index.last_search_stats().storage_name, "segmented-delta-scan-f32"
    )
    table.apply_delete(1, UInt64(11))
    assert_true(index.delete(1))
    _ = index.search([8.0, 0.0, 0.0], 1, 2, table, lookup)
    assert_equal(index.last_search_stats().storage_name, "segmented-f32")


def test_delta_scan_candidate_breadth_and_tie_cutoff() raises:
    var config = _config(MetricKind.l2(), ScalarKind.f32())
    var base = HnswIndex(config.copy())
    var table = MemTable(3)
    base.add(1, [100.0, 0.0, 0.0])
    table.apply_upsert(1, UInt64(1), [100.0, 0.0, 0.0])
    var index = SegmentedHnsw.from_owned(base^)
    # Equal distances arrive in reverse ID order across the heap cutoff.
    for id in [30, 20, 10]:
        index.upsert(id, [2.0, 0.0, 0.0])
        table.apply_upsert(id, UInt64(id), [2.0, 0.0, 0.0])
    var lookup = _lookup(table)
    var results = index.search([2.0, 0.0, 0.0], 2, 1, table, lookup)
    assert_equal(len(results), 2)
    assert_equal(results[0].id, 10)
    assert_equal(results[1].id, 20)
    assert_equal(index._delta.last_search_stats.retained_candidates, 2)
    assert_equal(index._delta.last_search_stats.effective_ef, 2)
    assert_equal(
        index.last_search_stats().storage_name, "segmented-delta-scan-f32"
    )
    var bitmap = Bitmap(table.slot_count())
    bitmap.set(1)
    bitmap.set(2)
    var allowed = HnswEligibility(bitmap^, lookup)
    results = index.search_allowed(
        [2.0, 0.0, 0.0], 2, 1, 128, allowed, table, lookup
    )
    assert_equal(results[0].id, 20)
    assert_equal(results[1].id, 30)
    assert_equal(index._delta.last_search_stats.filtered_rejections, 1)
    assert_equal(index._delta.last_search_stats.distance_evaluations, 2)
    assert_equal(index._delta.last_search_stats.widening_rounds, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
