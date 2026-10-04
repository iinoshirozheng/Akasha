from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.topk import BoundedTopK
from akasha.index.bitmap import Bitmap
from akasha.index.flat import authoritative_f32_score
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import encode_hnsw_snapshot, open_hnsw_snapshot_view
from akasha.storage.memtable import MemTable
from std.collections import Dict
from std.memory import bitcast
from std.testing import assert_equal, assert_true, TestSuite


def _lookup(table: MemTable) raises -> HnswIdOrdinalLookup:
    var ids = Dict[Int, Int]()
    for ordinal in range(table.slot_count()):
        ids[table.id_at(ordinal)] = ordinal
    return HnswIdOrdinalLookup(ids^, table.slot_count())


def _values(id: Int, revision: Float32 = 0) -> List[Float32]:
    return [Float32(id % 37 - 18) + revision, Float32((id * 13) % 41 - 20), 1.0]


def _check_history(metric: MetricKind, scalar: ScalarKind, mapped: Bool) raises:
    var config = CollectionConfig.defaults(3)
    config.ann_metric = metric.copy()
    config.scalar_kind = scalar.copy()
    config.m = 4
    config.m0 = 16
    config.ef_construction = 24
    config.default_ef_search = 128
    config.max_ef_search = 2048
    config.rebuild_inactive_percent = 90
    var base = HnswIndex(config.copy())
    var table = MemTable(3)
    base.add(-1, [-1000.0, 2.0, 1.0])
    table.apply_upsert(-1, 1, [-1000.0, 2.0, 1.0])
    var path = String("/tmp/akasha-live-history-base.bin")
    remove_file_if_exists(path)
    var index: SegmentedHnsw
    if mapped:
        write_file_sync(path, encode_hnsw_snapshot(base, 1))
        index = SegmentedHnsw.from_mapped(open_hnsw_snapshot_view(path, config, 1))
    else:
        index = SegmentedHnsw.from_owned(base^)
    var sequence = UInt64(1)
    for ordinal in range(600):
        var id = 100 + ordinal
        var values = _values(id)
        index.upsert(id, values)
        sequence += 1
        table.apply_upsert(id, sequence, values^)
    for ordinal in range(500):
        var id = 100 + ordinal
        var values = _values(id, 0.25)
        index.upsert(id, values)
        sequence += 1
        table.apply_upsert(id, sequence, values^)
    for ordinal in range(500, 510):
        var id = 100 + ordinal
        assert_true(index.delete(id))
        sequence += 1
        table.apply_delete(id, sequence)
    for ordinal in range(500, 510):
        var id = 100 + ordinal
        var values = _values(id, 0.5)
        index.upsert(id, values)
        sequence += 1
        table.apply_upsert(id, sequence, values^)
    assert_equal(index.delta_slot_count(), 1110)
    assert_equal(index._sources.delta_count(), 600)
    index.validate_structure()
    var lookup = _lookup(table)
    var query: List[Float32] = [2.0, -1.0, 1.0]
    for filtered in [False, True]:
        var allowed_bits = Bitmap(table.slot_count())
        var expected = BoundedTopK(601, smaller_is_better=metric == MetricKind.l2())
        var delta_scored = 0
        for ordinal in range(table.slot_count()):
            var id = table.id_at(ordinal)
            if table.is_live_at(ordinal) and (not filtered or id % 2 == 0):
                allowed_bits.set(ordinal)
                ref entry = table.entry_ref_at(ordinal)
                expected.offer(id, authoritative_f32_score(Int(metric.tag()), query, entry.values()))
                if id >= 100:
                    delta_scored += 1
        var allowed = HnswEligibility(allowed_bits^, lookup)
        var actual = index.search(query, 601, 1024, table, lookup)
        if filtered:
            actual = index.search_allowed(query, 601, 1024, 2048, allowed, table, lookup)
        assert_equal(index.last_search_stats().storage_name, String("segmented-delta-scan-", config.scalar_name()))
        var oracle = expected.sorted_entries()
        assert_equal(len(actual), len(oracle))
        for position in range(len(actual)):
            assert_equal(actual[position].id, oracle[position].id)
            assert_equal(bitcast[DType.uint32](actual[position].score), bitcast[DType.uint32](oracle[position].score))
        assert_equal(index._delta.last_search_stats.base_visited, 1110)
        assert_equal(index._delta.last_search_stats.inactive_rejections, 510)
        assert_equal(index._delta.last_search_stats.distance_evaluations, delta_scored)
        assert_equal(index._delta.last_search_upper_descents(), 0)
        assert_equal(index.last_search_stats().fallback_reason, "")
    index.close()
    remove_file_if_exists(path)


def test_history_over_1024_preserves_native_owned_and_mapped_results() raises:
    var scalars: List[ScalarKind] = [ScalarKind.f32(), ScalarKind.f16(), ScalarKind.bf16(), ScalarKind.i8()]
    var metrics: List[MetricKind] = [MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()]
    for scalar in scalars:
        for metric in metrics:
            if scalar == ScalarKind.i8() and metric == MetricKind.l2():
                continue
            for mapped in [False, True]:
                _check_history(metric, scalar, mapped)


def test_live_history_candidate_cutoff_and_physical_ceiling() raises:
    var config = CollectionConfig.defaults(3)
    config.ann_metric = MetricKind.l2()
    config.m = 4
    config.m0 = 16
    config.ef_construction = 24
    config.max_ef_search = 2048
    config.rebuild_inactive_percent = 90
    var base = HnswIndex(config.copy())
    var table = MemTable(3)
    base.add(-1, [10000.0, 0.0, 0.0])
    table.apply_upsert(-1, 1, [10000.0, 0.0, 0.0])
    var index = SegmentedHnsw.from_owned(base^)
    for id in range(600):
        var values: List[Float32] = [Float32(id // 2), 0.0, 0.0]
        index.upsert(id, values)
        table.apply_upsert(id, UInt64(id + 2), values^)
    for id in range(600):
        var values: List[Float32] = [Float32(id // 2), 0.0, 0.0]
        index.upsert(id, values)
    var lookup = _lookup(table)
    var query: List[Float32] = [-1.0, 0.0, 0.0]
    var actual = index.search(query, 10, 128, table, lookup)
    assert_equal(index.last_search_stats().storage_name, "segmented-delta-scan-f32")
    assert_equal(index._delta.last_search_stats.retained_candidates, 128)
    assert_equal(index._delta.last_search_stats.distance_evaluations, 600)
    for position in range(10):
        assert_equal(actual[position].id, position)
    var allowed_bits = Bitmap(table.slot_count())
    for ordinal in range(table.slot_count()):
        if table.id_at(ordinal) >= 0 and table.id_at(ordinal) % 2 == 1:
            allowed_bits.set(ordinal)
    var allowed = HnswEligibility(allowed_bits^, lookup)
    actual = index.search_allowed(query, 10, 128, 2048, allowed, table, lookup)
    assert_equal(index._delta.last_search_stats.filtered_rejections, 300)
    assert_equal(index._delta.last_search_stats.distance_evaluations, 300)
    for position in range(10):
        assert_equal(actual[position].id, position * 2 + 1)
    # One more historical slot exceeds twice live rows; graph stays available.
    index.upsert(0, [0.0, 0.0, 0.0])
    assert_equal(index.delta_slot_count(), 1201)
    _ = index.search(query, 10, 128, table, lookup)
    assert_equal(index.last_search_stats().storage_name, "segmented-f32")
    index.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
