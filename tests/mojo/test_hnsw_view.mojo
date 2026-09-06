from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.index.bitmap import Bitmap
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_view import HnswGraphView
from akasha.index.hnsw_core import (
    HnswEligibility,
    HnswIdOrdinalLookup,
    HnswSearchAdmission,
    greedy_descent,
    search_layer,
)
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import (
    decode_hnsw_snapshot_owned,
    encode_hnsw_snapshot,
    open_hnsw_snapshot_view,
)
from std.ffi import c_int, external_call
from std.collections import Dict
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)


def _path(suffix: String) -> String:
    return String(
        "/tmp/akasha-hnsw-view-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
        ".bin",
    )


def _config(metric: MetricKind) -> CollectionConfig:
    var config = CollectionConfig.defaults(3)
    config.ann_metric = metric.copy()
    config.scalar_kind = ScalarKind.f32()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 256
    config.max_level = 5
    config.level_seed = UInt64(0x17A5A17A5)
    return config^


def _vector(id: Int) -> List[Float32]:
    return [
        Float32((id * 17) % 29 + 1) * 0.1,
        Float32((id * 11 + 3) % 31 + 1) * 0.1,
        Float32((id * 7 + 5) % 23 + 1) * 0.1,
    ]


def _graph(config: CollectionConfig) raises -> HnswIndex:
    var index = HnswIndex(config)
    for id in range(1, 25):
        index.add(id, _vector(id))
    index.upsert(4, _vector(41))
    assert_true(index.delete(7))
    index.validate_structure()
    assert_true(index.entry_level > 0)
    return index^


def _put_u64(mut bytes: List[UInt8], offset: Int, value: UInt64):
    for index in range(8):
        bytes[offset + index] = UInt8(value >> UInt64(index * 8))


def _put_u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for index in range(4):
        bytes[offset + index] = UInt8(value >> UInt32(index * 8))


def _put_u16(mut bytes: List[UInt8], offset: Int, value: UInt16):
    for index in range(2):
        bytes[offset + index] = UInt8(value >> UInt16(index * 8))


def _u64_at(bytes: List[UInt8], offset: Int) -> UInt64:
    var result = UInt64(0)
    for index in range(8):
        result |= UInt64(bytes[offset + index]) << UInt64(index * 8)
    return result


def _seal(mut bytes: List[UInt8]):
    var checksum_offset = len(bytes) - 4
    _put_u32(bytes, checksum_offset, crc32_range(bytes, 0, checksum_offset))


def _expect_rejected(
    bytes: List[UInt8], config: CollectionConfig, suffix: String
) raises:
    var path = _path(suffix)
    write_file_sync(path, bytes)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, UInt64(93))


def _first_edge(bytes: List[UInt8]) raises -> Tuple[Int, UInt32]:
    var slots = Int(_u64_at(bytes, 48))
    var counts = Int(_u64_at(bytes, 120))
    var edges = Int(_u64_at(bytes, 136))
    for source in range(slots):
        var node = 160 + source * 40
        var levels = (
            Int(
                UInt16(bytes[node + 8]) | (UInt16(bytes[node + 9]) << UInt16(8))
            )
            + 1
        )
        var count_base = Int(_u64_at(bytes, node + 16))
        var edge_base = Int(_u64_at(bytes, node + 24))
        for level in range(levels):
            var count_offset = counts + (count_base + level) * 4
            var count = Int(
                UInt32(bytes[count_offset])
                | (UInt32(bytes[count_offset + 1]) << UInt32(8))
                | (UInt32(bytes[count_offset + 2]) << UInt32(16))
                | (UInt32(bytes[count_offset + 3]) << UInt32(24))
            )
            if count > 0:
                return (edges + edge_base * 4, UInt32(source))
            edge_base += count
    raise Error("test graph has no edges")


def _assert_search_stats_equal(
    lhs: HnswSearchStats, rhs: HnswSearchStats
) raises:
    assert_equal(lhs.requested_ef, rhs.requested_ef)
    assert_equal(lhs.effective_ef, rhs.effective_ef)
    assert_equal(lhs.widening_rounds, rhs.widening_rounds)
    assert_equal(lhs.upper_visited, rhs.upper_visited)
    assert_equal(lhs.base_visited, rhs.base_visited)
    assert_equal(lhs.distance_evaluations, rhs.distance_evaluations)
    assert_equal(lhs.retained_candidates, rhs.retained_candidates)
    assert_equal(lhs.reranked_candidates, rhs.reranked_candidates)
    assert_equal(lhs.filtered_rejections, rhs.filtered_rejections)
    assert_equal(lhs.inactive_rejections, rhs.inactive_rejections)
    assert_equal(lhs.base_candidates, rhs.base_candidates)
    assert_equal(lhs.delta_candidates, rhs.delta_candidates)
    assert_equal(lhs.backend_name, rhs.backend_name)
    assert_equal(lhs.metric_name, rhs.metric_name)
    assert_equal(lhs.scalar_name, rhs.scalar_name)
    assert_equal(lhs.fallback_reason, rhs.fallback_reason)


def test_owned_and_mapped_views_are_search_equivalent_for_all_metrics() raises:
    var metrics: List[MetricKind] = [
        MetricKind.dot(),
        MetricKind.l2(),
        MetricKind.cosine(),
    ]
    for metric_index in range(len(metrics)):
        var config = _config(metrics[metric_index])
        var original = _graph(config.copy())
        var bytes = encode_hnsw_snapshot(original, UInt64(91))
        var owned = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(91))
        var path = _path(String("equivalence-", metric_index))
        remove_file_if_exists(path)
        write_file_sync(path, bytes)
        var view = open_hnsw_snapshot_view(path, config, UInt64(91))

        view.validate_structure()
        assert_equal(view.slot_count(), owned.graph.slot_count())
        assert_equal(view.entry_slot(), owned.entry_slot.value())
        assert_equal(view.entry_level(), owned.entry_level)
        for slot_index in range(owned.graph.slot_count()):
            var slot = UInt32(slot_index)
            assert_equal(view.id_at(slot), owned.graph.id_at(slot))
            assert_equal(view.level(slot), owned.graph.level(slot))
            assert_equal(view.is_current(slot), owned.graph.is_current(slot))
            for component in range(config.dimension):
                assert_equal(
                    view.vector_value(slot, component),
                    owned.graph.vector_value(slot, component),
                )
            for level in range(owned.graph.level(slot) + 1):
                assert_equal(
                    view.neighbor_count(slot, level),
                    owned.graph.neighbor_count(slot, level),
                )
                for edge_index in range(
                    owned.graph.neighbor_count(slot, level)
                ):
                    assert_equal(
                        view.neighbor_at(slot, level, edge_index),
                        owned.graph.neighbor_at(slot, level, edge_index),
                    )

        var query = _vector(13)
        var owned_results = owned.search(query, 8, ef_search=32)
        var view_results = view.search(query, 8, ef_search=32)
        assert_equal(len(view_results), len(owned_results))
        for index in range(len(owned_results)):
            assert_equal(view_results[index].id, owned_results[index].id)
            assert_almost_equal(
                view_results[index].score,
                owned_results[index].score,
                atol=1.0e-6,
            )
        _assert_search_stats_equal(
            view.last_search_stats(), owned.last_search_stats
        )
        assert_equal(view.last_search_stats().storage_name, "mapped-f32")
        assert_equal(owned.last_search_stats.storage_name, "packed-f32")


def test_core_candidate_order_is_identical_for_owned_and_view() raises:
    var config = _config(MetricKind.l2())
    var original = _graph(config.copy())
    var path = _path("candidate-order")
    remove_file_if_exists(path)
    write_file_sync(path, encode_hnsw_snapshot(original, UInt64(92)))
    var view = open_hnsw_snapshot_view(path, config, UInt64(92))
    var query = original.metric.prepare_query(_vector(9))
    var owned_entry = original.entry_slot.value()
    var view_entry = view.entry_slot()
    var owned_stats = HnswSearchStats()
    var view_stats = HnswSearchStats()
    for level in range(original.entry_level, 0, -1):
        owned_entry = greedy_descent(
            original.graph,
            original.metric,
            query,
            owned_entry,
            level,
            owned_stats,
        ).slot
        view_entry = greedy_descent(
            view,
            view.metric(),
            query,
            view_entry,
            level,
            view_stats,
        ).slot
    var owned_scratch = HnswSearchScratch()
    var view_scratch = HnswSearchScratch()
    var admission = HnswSearchAdmission()
    var owned = search_layer(
        original.graph,
        original.metric,
        query,
        owned_entry,
        0,
        12,
        32,
        admission,
        owned_scratch,
        owned_stats,
    )
    var mapped = search_layer(
        view,
        view.metric(),
        query,
        view_entry,
        0,
        12,
        32,
        admission,
        view_scratch,
        view_stats,
    )
    assert_equal(len(mapped), len(owned))
    for index in range(len(owned)):
        assert_equal(mapped[index].slot, owned[index].slot)
        assert_equal(mapped[index].id, owned[index].id)
        assert_equal(mapped[index].distance, owned[index].distance)
    _assert_search_stats_equal(view_stats, owned_stats)


def test_owned_and_mapped_filtered_widening_share_prepare_once_core() raises:
    var config = _config(MetricKind.l2())
    var original = _graph(config.copy())
    var path = _path("filtered-widening")
    remove_file_if_exists(path)
    write_file_sync(path, encode_hnsw_snapshot(original, UInt64(94)))
    var view = open_hnsw_snapshot_view(path, config, UInt64(94))
    var ordinals = Dict[Int, Int]()
    var allowed_bitmap = Bitmap(24)
    for id in range(1, 25):
        ordinals[id] = id - 1
        if id % 2 == 0:
            allowed_bitmap.set(id - 1)
    var lookup = HnswIdOrdinalLookup(ordinals^, 24)
    var owned_allowed = HnswEligibility(allowed_bitmap.clone(), lookup)
    var mapped_allowed = HnswEligibility(allowed_bitmap^, lookup)
    var query = _vector(13)

    var owned = original.search_allowed_with_widening(
        query, 5, 2, 16, owned_allowed
    )
    var mapped = view.search_allowed_with_widening(
        query, 5, 2, 16, mapped_allowed
    )

    assert_equal(len(mapped), len(owned))
    for index in range(len(owned)):
        assert_equal(mapped[index].id, owned[index].id)
        assert_almost_equal(mapped[index].score, owned[index].score, atol=1.0e-6)
    _assert_search_stats_equal(
        view.last_search_stats(), original.last_search_stats
    )
    assert_equal(original.last_search_query_preparations(), 1)
    assert_equal(view.last_search_query_preparations(), 1)
    assert_equal(
        view.last_search_upper_descents(),
        original.last_search_upper_descents(),
    )

    var candidate_bitmap = Bitmap(24)
    for id in range(1, 25):
        if id % 2 == 0:
            candidate_bitmap.set(id - 1)
    var owned_candidate_allowed = HnswEligibility(
        candidate_bitmap.clone(), lookup
    )
    var mapped_candidate_allowed = HnswEligibility(candidate_bitmap^, lookup)
    var owned_candidates = original.search_allowed_candidates_with_widening(
        query, 5, 8, 8, owned_candidate_allowed
    )
    var mapped_candidates = view.search_allowed_candidates_with_widening(
        query, 5, 8, 8, mapped_candidate_allowed
    )
    assert_equal(len(owned_candidates), 8)
    assert_equal(len(mapped_candidates), len(owned_candidates))
    for index in range(len(owned_candidates)):
        assert_equal(mapped_candidates[index].id, owned_candidates[index].id)
        assert_almost_equal(
            mapped_candidates[index].score,
            owned_candidates[index].score,
            atol=1.0e-6,
        )
    _assert_search_stats_equal(
        view.last_search_stats(), original.last_search_stats
    )


def test_view_rejects_misalignment_aliasing_order_and_truncation() raises:
    var config = _config(MetricKind.l2())
    var bytes = encode_hnsw_snapshot(_graph(config.copy()), UInt64(93))

    var misaligned = bytes.copy()
    _put_u64(misaligned, 104, _u64_at(misaligned, 104) + UInt64(1))
    _seal(misaligned)
    var path = _path("misaligned")
    write_file_sync(path, misaligned)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, UInt64(93))

    var aliased = bytes.copy()
    _put_u64(aliased, 104, _u64_at(aliased, 88))
    _seal(aliased)
    path = _path("aliased")
    write_file_sync(path, aliased)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, UInt64(93))

    var out_of_order = bytes.copy()
    _put_u64(out_of_order, 120, _u64_at(out_of_order, 104) - UInt64(8))
    _seal(out_of_order)
    path = _path("out-of-order")
    write_file_sync(path, out_of_order)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, UInt64(93))

    var truncated = bytes.copy()
    _ = truncated.pop()
    path = _path("truncated")
    write_file_sync(path, truncated)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, UInt64(93))


def test_view_rejects_invalid_nodes_vectors_counts_edges_and_entry() raises:
    var config = _config(MetricKind.l2())
    var bytes = encode_hnsw_snapshot(_graph(config.copy()), UInt64(93))

    var duplicate_id = bytes.copy()
    for index in range(8):
        duplicate_id[200 + index] = duplicate_id[160 + index]
    _seal(duplicate_id)
    _expect_rejected(duplicate_id, config, "duplicate-id")

    var bad_level = bytes.copy()
    _put_u16(bad_level, 168, UInt16(config.max_level + 1))
    _seal(bad_level)
    _expect_rejected(bad_level, config, "bad-level")

    var bad_vector = bytes.copy()
    _put_u32(bad_vector, Int(_u64_at(bad_vector, 104)), UInt32(0x7FC00000))
    _seal(bad_vector)
    _expect_rejected(bad_vector, config, "bad-vector")

    var bad_count = bytes.copy()
    _put_u32(
        bad_count,
        Int(_u64_at(bad_count, 120)),
        UInt32(config.m0 + 1),
    )
    _seal(bad_count)
    _expect_rejected(bad_count, config, "bad-count")

    var bad_edge = bytes.copy()
    var first_edge = _first_edge(bad_edge)
    _put_u32(bad_edge, first_edge[0], first_edge[1])
    _seal(bad_edge)
    _expect_rejected(bad_edge, config, "bad-edge")

    var bad_entry = bytes.copy()
    _put_u64(bad_entry, 72, _u64_at(bad_entry, 48))
    _seal(bad_entry)
    _expect_rejected(bad_entry, config, "bad-entry")


def test_view_rejects_checksum_header_sequence_and_config_mismatch() raises:
    var config = _config(MetricKind.l2())
    var bytes = encode_hnsw_snapshot(_graph(config.copy()), UInt64(93))

    var bad_checksum = bytes.copy()
    bad_checksum[160] ^= UInt8(1)
    _expect_rejected(bad_checksum, config, "bad-checksum")

    var bad_magic = bytes.copy()
    bad_magic[0] = UInt8(0)
    _seal(bad_magic)
    _expect_rejected(bad_magic, config, "bad-magic")

    var path = _path("wrong-sequence")
    write_file_sync(path, bytes)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, UInt64(94))

    var other = config.copy()
    other.level_seed += UInt64(1)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, other, UInt64(93))


def test_view_owner_close_prevents_all_later_access() raises:
    var config = _config(MetricKind.l2())
    var path = _path("close")
    write_file_sync(
        path,
        encode_hnsw_snapshot(_graph(config.copy()), UInt64(94)),
    )
    var view = open_hnsw_snapshot_view(path, config, UInt64(94))
    assert_true(view.slot_count() > 0)
    view.close()
    view.close()
    with assert_raises():
        _ = view.id_at(UInt32(0))
    with assert_raises():
        view.validate_structure()
    with assert_raises():
        _ = view.search(_vector(2), 3, ef_search=16)


def test_empty_snapshot_and_default_view_are_safe() raises:
    var config = _config(MetricKind.l2())
    var path = _path("empty")
    write_file_sync(
        path,
        encode_hnsw_snapshot(HnswIndex(config), UInt64(95)),
    )
    var view = open_hnsw_snapshot_view(path, config, UInt64(95))
    view.validate_structure()
    assert_equal(view.slot_count(), 0)
    assert_equal(len(view.search(_vector(2), 3, ef_search=16)), 0)
    with assert_raises():
        _ = view.entry_slot()

    var default_view = HnswGraphView()
    default_view.close()
    with assert_raises():
        default_view.validate_structure()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
