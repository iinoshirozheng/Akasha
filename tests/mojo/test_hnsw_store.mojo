from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.index.hnsw import HnswIndex
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.hnsw_store import (
    _validate_hnsw_snapshot_header_allocation,
    decode_hnsw_snapshot_owned,
    encode_hnsw_snapshot,
    hnsw_snapshot_eligibility,
    hnsw_snapshot_identity_matches,
    read_hnsw_snapshot_owned,
    write_hnsw_snapshot,
)
from std.memory import bitcast
from std.sys.info import is_64bit
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _config(metric: MetricKind = MetricKind.l2()) -> CollectionConfig:
    var config = CollectionConfig.defaults(2)
    config.ann_metric = metric.copy()
    config.scalar_kind = ScalarKind.f32()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 1_024
    config.max_level = 4
    config.level_seed = UInt64(0x17A5A17A5)
    return config^


def _vector(x: Float32, y: Float32) -> List[Float32]:
    return [x, y]


def _graph(config: CollectionConfig, count: Int = 12) raises -> HnswIndex:
    var index = HnswIndex(config)
    for id in range(count):
        index.add(
            id + 1,
            _vector(
                Float32((id * 17) % 29) * 0.1,
                Float32((id * 11 + 3) % 31) * 0.1,
            ),
        )
    index.validate_structure()
    return index^


def _assert_same_graph(lhs: HnswIndex, rhs: HnswIndex) raises:
    assert_equal(lhs.point_count(), rhs.point_count())
    assert_equal(lhs.inactive_count(), rhs.inactive_count())
    assert_equal(lhs.entry_slot.value(), rhs.entry_slot.value())
    assert_equal(lhs.entry_level, rhs.entry_level)
    for slot_index in range(lhs.point_count()):
        var slot = UInt32(slot_index)
        assert_equal(lhs.graph.id_at(slot), rhs.graph.id_at(slot))
        assert_equal(lhs.graph.level(slot), rhs.graph.level(slot))
        assert_equal(lhs.graph.is_current(slot), rhs.graph.is_current(slot))
        assert_equal(lhs.graph.is_deleted(slot), rhs.graph.is_deleted(slot))
        assert_equal(lhs.graph.is_replaced(slot), rhs.graph.is_replaced(slot))
        for component in range(lhs.dimension):
            assert_equal(
                lhs.graph.vector_value(slot, component),
                rhs.graph.vector_value(slot, component),
            )
        for level in range(lhs.graph.level(slot) + 1):
            assert_equal(
                lhs.graph.neighbor_count(slot, level),
                rhs.graph.neighbor_count(slot, level),
            )
            for edge_index in range(lhs.graph.neighbor_count(slot, level)):
                assert_equal(
                    lhs.graph.neighbor_at(slot, level, edge_index),
                    rhs.graph.neighbor_at(slot, level, edge_index),
                )
    lhs.validate_structure()
    rhs.validate_structure()


def test_identity_preflight_reads_fixed_header_without_payload_copy() raises:
    var config = _config()
    var index = _graph(config.copy(), 12)
    var bytes = encode_hnsw_snapshot(index, UInt64(44))
    assert_true(
        hnsw_snapshot_identity_matches(
            bytes, config, UInt64(44), UInt64(12)
        )
    )
    # Compatibility classification is deliberately independent of payload
    # traversal; CRC/layout validation follows only for matching identity.
    bytes[160] ^= UInt8(1)
    assert_true(
        hnsw_snapshot_identity_matches(
            bytes, config, UInt64(44), UInt64(12)
        )
    )


def test_eligibility_distinguishes_invalid_graph_from_codec_limit() raises:
    var config = _config()
    var index = _graph(config, 4)
    index.valid = False
    var eligibility = hnsw_snapshot_eligibility(index, UInt64.MAX)
    assert_false(eligibility.eligible)
    assert_false(eligibility.graph_usable)
    assert_equal(eligibility.reason, "invalid_graph")


def _u16_at(bytes: List[UInt8], offset: Int) -> UInt16:
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << UInt16(8))


def _u32_at(bytes: List[UInt8], offset: Int) -> UInt32:
    return (
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )


def _u64_at(bytes: List[UInt8], offset: Int) -> UInt64:
    var result = UInt64(0)
    for index in range(8):
        result |= UInt64(bytes[offset + index]) << UInt64(index * 8)
    return result


def _put_u16(mut bytes: List[UInt8], offset: Int, value: UInt16):
    for index in range(2):
        bytes[offset + index] = UInt8(value >> UInt16(index * 8))


def _put_u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for index in range(4):
        bytes[offset + index] = UInt8(value >> UInt32(index * 8))


def _put_u64(mut bytes: List[UInt8], offset: Int, value: UInt64):
    for index in range(8):
        bytes[offset + index] = UInt8(value >> UInt64(index * 8))


def _seal(mut bytes: List[UInt8]):
    var checksum_offset = len(bytes) - 4
    var checksum = crc32_range(bytes, 0, checksum_offset)
    _put_u32(bytes, checksum_offset, checksum)


def _first_multi_edge_offset(bytes: List[UInt8]) raises -> Int:
    var slots = Int(_u64_at(bytes, 48))
    var count_section = Int(_u64_at(bytes, 120))
    var edge_section = Int(_u64_at(bytes, 136))
    for slot_index in range(slots):
        var node = 160 + slot_index * 40
        var level_count = Int(_u16_at(bytes, node + 8)) + 1
        var count_base = Int(_u64_at(bytes, node + 16))
        var edge_base = Int(_u64_at(bytes, node + 24))
        var local_edge_base = edge_base
        for level in range(level_count):
            var count = Int(
                _u32_at(bytes, count_section + (count_base + level) * 4)
            )
            if count >= 2:
                return edge_section + local_edge_base * 4
            local_edge_base += count
    raise Error("test graph has no multi-edge adjacency")


def _first_asymmetry_candidate(bytes: List[UInt8]) raises -> Tuple[Int, UInt32]:
    var slots = Int(_u64_at(bytes, 48))
    var count_section = Int(_u64_at(bytes, 120))
    var edge_section = Int(_u64_at(bytes, 136))
    for source in range(slots):
        var node = 160 + source * 40
        var level_count = Int(_u16_at(bytes, node + 8)) + 1
        var count_base = Int(_u64_at(bytes, node + 16))
        var edge_base = Int(_u64_at(bytes, node + 24))
        var local_edge_base = edge_base
        for level in range(level_count):
            var count = Int(
                _u32_at(bytes, count_section + (count_base + level) * 4)
            )
            if count > 0:
                for candidate in range(slots):
                    if candidate == source:
                        continue
                    var candidate_level = Int(
                        _u16_at(bytes, 160 + candidate * 40 + 8)
                    )
                    if candidate_level < level:
                        continue
                    var present = False
                    for edge_index in range(count):
                        if (
                            Int(
                                _u32_at(
                                    bytes,
                                    edge_section
                                    + (local_edge_base + edge_index) * 4,
                                )
                            )
                            == candidate
                        ):
                            present = True
                    if not present:
                        return (
                            edge_section + local_edge_base * 4,
                            UInt32(candidate),
                        )
            local_edge_base += count
    raise Error("test graph has no asymmetric mutation candidate")


def test_empty_single_and_multi_level_snapshots_round_trip_deterministically() raises:
    var config = _config()
    var empty = HnswIndex(config)
    var empty_bytes = encode_hnsw_snapshot(empty, UInt64(0))
    var decoded_empty = decode_hnsw_snapshot_owned(
        empty_bytes.copy(), config, UInt64(0)
    )
    assert_equal(decoded_empty.point_count(), 0)
    assert_false(Bool(decoded_empty.entry_slot))

    var single = HnswIndex(config)
    single.add(7, _vector(1.0, 2.0))
    var single_bytes = encode_hnsw_snapshot(single, UInt64(11))
    var decoded_single = decode_hnsw_snapshot_owned(
        single_bytes.copy(), config, UInt64(11)
    )
    _assert_same_graph(single, decoded_single)

    var multi = _graph(config)
    assert_true(multi.entry_level > 0)
    var first = encode_hnsw_snapshot(multi, UInt64(19))
    var second = encode_hnsw_snapshot(multi, UInt64(19))
    assert_equal(first, second)
    var decoded_multi = decode_hnsw_snapshot_owned(
        first.copy(), config, UInt64(19)
    )
    _assert_same_graph(multi, decoded_multi)


def test_tombstones_replacements_and_rebuilt_graphs_round_trip() raises:
    var config = _config()
    var index = _graph(config, 8)
    index.upsert(3, _vector(9.0, 1.0))
    assert_true(index.delete(5))
    var bytes = encode_hnsw_snapshot(index, UInt64(23))
    var decoded = decode_hnsw_snapshot_owned(bytes^, config, UInt64(23))
    _assert_same_graph(index, decoded)
    assert_true(decoded.graph.is_replaced(UInt32(2)))
    assert_true(decoded.inactive_count() >= 2)

    var rebuilt = _graph(config, 6)
    var rebuilt_decoded = decode_hnsw_snapshot_owned(
        encode_hnsw_snapshot(rebuilt, UInt64(24)), config, UInt64(24)
    )
    assert_equal(rebuilt_decoded.inactive_count(), 0)
    _assert_same_graph(rebuilt, rebuilt_decoded)

    var all_tombstoned = _graph(config, 3)
    for id in range(1, 4):
        assert_true(all_tombstoned.delete(id))
    var all_tombstoned_decoded = decode_hnsw_snapshot_owned(
        encode_hnsw_snapshot(all_tombstoned, UInt64(25)),
        config,
        UInt64(25),
    )
    assert_equal(all_tombstoned_decoded.inactive_count(), 3)
    assert_equal(len(all_tombstoned_decoded.search(_vector(0.0, 0.0), 3)), 0)
    _assert_same_graph(all_tombstoned, all_tombstoned_decoded)


def test_all_f32_metrics_preserve_queries_after_owned_decode() raises:
    var metrics: List[MetricKind] = [
        MetricKind.dot(),
        MetricKind.l2(),
        MetricKind.cosine(),
    ]
    for metric in metrics:
        var config = _config(metric)
        var index = _graph(config)
        var query = _vector(0.7, 1.3)
        var expected = index.search(query, 5, ef_search=32)
        var bytes = encode_hnsw_snapshot(index, UInt64(31))
        var decoded = decode_hnsw_snapshot_owned(
            bytes.copy(), config, UInt64(31)
        )
        bytes[0] = UInt8(0)
        var actual = decoded.search(query, 5, ef_search=32)
        assert_equal(len(actual), len(expected))
        for result_index in range(len(expected)):
            assert_equal(actual[result_index].id, expected[result_index].id)
            assert_almost_equal(
                actual[result_index].score,
                expected[result_index].score,
                atol=1.0e-6,
            )


def test_rejects_crc_valid_unprepared_durable_vectors() raises:
    var cosine_config = _config(MetricKind.cosine())
    var cosine = _graph(cosine_config, 4)
    var cosine_bytes = encode_hnsw_snapshot(cosine, UInt64(35))
    var cosine_vectors = Int(_u64_at(cosine_bytes, 104))

    var zero_cosine = cosine_bytes.copy()
    _put_u32(zero_cosine, cosine_vectors, UInt32(0))
    _put_u32(zero_cosine, cosine_vectors + 4, UInt32(0))
    _seal(zero_cosine)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(zero_cosine^, cosine_config, UInt64(35))

    var nonunit_cosine = cosine_bytes.copy()
    _put_u32(
        nonunit_cosine,
        cosine_vectors,
        bitcast[DType.uint32](Float32(0.5)),
    )
    _put_u32(
        nonunit_cosine,
        cosine_vectors + 4,
        bitcast[DType.uint32](Float32(0.5)),
    )
    _seal(nonunit_cosine)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(
            nonunit_cosine^, cosine_config, UInt64(35)
        )

    var large_component = bitcast[DType.uint32](Float32(1.0e20))
    var metrics: List[MetricKind] = [MetricKind.dot(), MetricKind.l2()]
    for metric in metrics:
        var config = _config(metric)
        var index = _graph(config, 4)
        var bytes = encode_hnsw_snapshot(index, UInt64(36))
        _put_u32(bytes, Int(_u64_at(bytes, 104)), large_component)
        _seal(bytes)
        with assert_raises():
            _ = decode_hnsw_snapshot_owned(bytes^, config, UInt64(36))


def test_encoder_rejects_mutated_unprepared_graph_vector() raises:
    var config = _config(MetricKind.cosine())
    var index = _graph(config, 4)
    index.graph.vector_scalars[0] = Float32(0.0)
    index.graph.vector_scalars[1] = Float32(0.0)
    with assert_raises():
        _ = encode_hnsw_snapshot(index, UInt64(37))

    var dot_config = _config(MetricKind.dot())
    var dot = _graph(dot_config, 4)
    dot.graph.vector_scalars[0] = Float32(1.0e20)
    with assert_raises():
        _ = encode_hnsw_snapshot(dot, UInt64(37))


def test_v1_rejects_non_f32_empty_and_nonempty_graphs() raises:
    assert_true(is_64bit())
    var f32_config = _config(MetricKind.dot())
    var f32_empty = HnswIndex(f32_config)
    var encoded_empty = encode_hnsw_snapshot(f32_empty, UInt64(38))
    var f32_nonempty = _graph(f32_config, 2)
    var encoded_nonempty = encode_hnsw_snapshot(f32_nonempty, UInt64(38))
    var scalar_kinds: List[ScalarKind] = [
        ScalarKind.bf16(),
        ScalarKind.f16(),
        ScalarKind.i8(),
    ]
    for scalar in scalar_kinds:
        var config = f32_config.copy()
        config.scalar_kind = scalar.copy()

        var empty = HnswIndex(config)
        with assert_raises():
            _ = encode_hnsw_snapshot(empty, UInt64(38))

        var nonempty = HnswIndex(config)
        _ = nonempty.graph.append(7, _vector(1.0, 2.0), 0)
        nonempty.entry_slot = Optional(UInt32(0))
        nonempty.entry_level = 0
        nonempty.build_stats.slot_count = 1
        nonempty.build_stats.maximum_level = 0
        nonempty.validate_structure()
        with assert_raises():
            _ = encode_hnsw_snapshot(nonempty, UInt64(38))

        var bytes = encoded_empty.copy()
        _put_u64(bytes, 16, config.fingerprint())
        bytes[37] = scalar.tag()
        _seal(bytes)
        with assert_raises():
            _ = decode_hnsw_snapshot_owned(bytes^, config, UInt64(38))
        var nonempty_bytes = encoded_nonempty.copy()
        _put_u64(nonempty_bytes, 16, config.fingerprint())
        nonempty_bytes[37] = scalar.tag()
        _seal(nonempty_bytes)
        with assert_raises():
            _ = decode_hnsw_snapshot_owned(nonempty_bytes^, config, UInt64(38))


def test_file_helpers_report_metadata_and_read_owned_snapshot() raises:
    var directory = "/tmp/akasha-hnsw-sidecar-v1"
    ensure_directory(directory)
    var path = directory + "/hnsw-41.bin"
    remove_file_if_exists(path)
    var config = _config()
    var index = _graph(config, 6)
    var info = write_hnsw_snapshot(path, index, UInt64(41))
    assert_equal(info.sequence, UInt64(41))
    assert_equal(info.config_fingerprint, config.fingerprint())
    assert_equal(info.slot_count, UInt64(index.point_count()))
    assert_equal(info.live_point_count, UInt64(6))
    assert_equal(info.byte_length, UInt64(len(read_file_bytes(path))))
    var decoded = read_hnsw_snapshot_owned(path, config, UInt64(41))
    _assert_same_graph(index, decoded)


def test_rejects_truncation_checksum_magic_version_flags_and_reserved_bytes() raises:
    var config = _config()
    var bytes = encode_hnsw_snapshot(_graph(config), UInt64(51))
    var truncated_header = List[UInt8]()
    for index in range(40):
        truncated_header.append(bytes[index])
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(truncated_header^, config, UInt64(51))
    var truncated_section = bytes.copy()
    _ = truncated_section.pop()
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(truncated_section^, config, UInt64(51))
    var checksum_valid_short_section = bytes.copy()
    for _ in range(8):
        _ = checksum_valid_short_section.pop()
    for _ in range(4):
        checksum_valid_short_section.append(UInt8(0))
    _seal(checksum_valid_short_section)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(
            checksum_valid_short_section^, config, UInt64(51)
        )

    var bad_checksum = bytes.copy()
    bad_checksum[200] ^= UInt8(1)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_checksum^, config, UInt64(51))
    var bad_magic = bytes.copy()
    bad_magic[0] = UInt8(0)
    _seal(bad_magic)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_magic^, config, UInt64(51))
    var bad_version = bytes.copy()
    _put_u16(bad_version, 4, UInt16(2))
    _seal(bad_version)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_version^, config, UInt64(51))
    var bad_flags = bytes.copy()
    _put_u16(bad_flags, 6, UInt16(1))
    _seal(bad_flags)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_flags^, config, UInt64(51))
    var bad_reserved = bytes.copy()
    bad_reserved[12] = UInt8(1)
    _seal(bad_reserved)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_reserved^, config, UInt64(51))
    var bad_node_reserved = bytes.copy()
    bad_node_reserved[171] = UInt8(1)
    _seal(bad_node_reserved)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_node_reserved^, config, UInt64(51))
    var bad_node_flags = bytes.copy()
    bad_node_flags[170] = UInt8(3)
    _seal(bad_node_flags)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_node_flags^, config, UInt64(51))

    var padding_graph = HnswIndex(config)
    padding_graph.add(7, _vector(1.0, 2.0))
    var bad_padding = encode_hnsw_snapshot(padding_graph, UInt64(51))
    var vector_end = Int(_u64_at(bad_padding, 104) + _u64_at(bad_padding, 112))
    var count_start = Int(_u64_at(bad_padding, 120))
    var count_end = Int(_u64_at(bad_padding, 120) + _u64_at(bad_padding, 128))
    var edge_start = Int(_u64_at(bad_padding, 136))
    if count_start > vector_end:
        bad_padding[vector_end] = UInt8(1)
    elif edge_start > count_end:
        bad_padding[count_end] = UInt8(1)
    else:
        raise Error("test fixture unexpectedly has no alignment padding")
    _seal(bad_padding)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_padding^, config, UInt64(51))


def test_rejects_sequence_config_dimension_metric_and_scalar_mismatches() raises:
    var config = _config()
    var bytes = encode_hnsw_snapshot(_graph(config), UInt64(61))
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(62))
    var other_config = config.copy()
    other_config.level_seed += UInt64(1)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bytes.copy(), other_config, UInt64(61))

    var bad_dimension = bytes.copy()
    _put_u32(bad_dimension, 32, UInt32(3))
    _seal(bad_dimension)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_dimension^, config, UInt64(61))
    var bad_metric = bytes.copy()
    bad_metric[36] = MetricKind.dot().tag()
    _seal(bad_metric)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_metric^, config, UInt64(61))
    var bad_scalar = bytes.copy()
    bad_scalar[37] = ScalarKind.f16().tag()
    _seal(bad_scalar)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_scalar^, config, UInt64(61))


def test_rejects_overflowing_counts_offsets_and_ranges() raises:
    var config = _config()
    var bytes = encode_hnsw_snapshot(_graph(config), UInt64(71))
    var huge_slots = bytes.copy()
    _put_u64(huge_slots, 48, UInt64.MAX)
    _seal(huge_slots)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(huge_slots^, config, UInt64(71))
    var huge_edges = bytes.copy()
    _put_u64(huge_edges, 64, UInt64.MAX)
    _seal(huge_edges)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(huge_edges^, config, UInt64(71))
    var huge_offset = bytes.copy()
    _put_u64(huge_offset, 104, UInt64.MAX)
    _seal(huge_offset)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(huge_offset^, config, UInt64(71))
    var overlapping = bytes.copy()
    _put_u64(overlapping, 120, _u64_at(overlapping, 104))
    _seal(overlapping)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(overlapping^, config, UInt64(71))


def test_header_preflight_rejects_hostile_counts() raises:
    # Decoder call order is guaranteed by its preflight-before-staging
    # structure; this seam narrowly verifies the hostile-header rejection.
    with assert_raises():
        _validate_hnsw_snapshot_header_allocation(
            UInt64(1_024),
            UInt64(10_000_000),
            UInt64(2),
            UInt64(10_000_000),
            UInt64(0),
            UInt64(8),
        )


def test_rejects_invalid_entry_level_and_slot() raises:
    var config = _config()
    var bytes = encode_hnsw_snapshot(_graph(config), UInt64(81))
    var bad_slot = bytes.copy()
    _put_u64(bad_slot, 72, _u64_at(bad_slot, 48))
    _seal(bad_slot)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_slot^, config, UInt64(81))
    var bad_level = bytes.copy()
    _put_u64(bad_level, 80, UInt64(63))
    _seal(bad_level)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bad_level^, config, UInt64(81))


def test_rejects_duplicate_current_public_ids() raises:
    var config = _config()
    var bytes = encode_hnsw_snapshot(_graph(config), UInt64(86))
    var duplicate = bytes.copy()
    _put_u64(duplicate, 160 + 40, _u64_at(duplicate, 160))
    _seal(duplicate)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(duplicate^, config, UInt64(86))


def test_rejects_out_of_range_self_duplicate_and_asymmetric_links() raises:
    var config = _config()
    var bytes = encode_hnsw_snapshot(_graph(config, 18), UInt64(91))
    var edge_offset = Int(_u64_at(bytes, 136))
    var out_of_range = bytes.copy()
    _put_u32(out_of_range, edge_offset, UInt32(_u64_at(bytes, 48)))
    _seal(out_of_range)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(out_of_range^, config, UInt64(91))
    var self_edge = bytes.copy()
    _put_u32(self_edge, edge_offset, UInt32(0))
    _seal(self_edge)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(self_edge^, config, UInt64(91))
    var duplicate = bytes.copy()
    var multi_offset = _first_multi_edge_offset(duplicate)
    _put_u32(duplicate, multi_offset + 4, _u32_at(duplicate, multi_offset))
    _seal(duplicate)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(duplicate^, config, UInt64(91))
    var asymmetric = bytes.copy()
    var mutation = _first_asymmetry_candidate(asymmetric)
    _put_u32(asymmetric, mutation[0], mutation[1])
    _seal(asymmetric)
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(asymmetric^, config, UInt64(91))


def test_legacy_cache_fixture_remains_readable_and_sidecar_is_independent() raises:
    var fixture: List[UInt8] = [
        4,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        7,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        128,
        63,
        0,
        0,
        0,
        64,
        0,
        0,
        0,
        0,
    ]
    var legacy = HnswIndex.decode_cache_payload(2, fixture.copy())
    assert_equal(legacy.point_count(), 1)
    assert_equal(legacy.entry_point_id(), 7)

    var directory = "/tmp/akasha-hnsw-cache-transition"
    ensure_directory(directory)
    var cache_path = directory + "/hnsw.cache"
    var sidecar_path = directory + "/hnsw-101.bin"
    write_file_sync(cache_path, fixture)
    var config = _config()
    var current = _graph(config, 4)
    _ = write_hnsw_snapshot(sidecar_path, current, UInt64(101))
    assert_equal(read_file_bytes(cache_path), fixture)
    var sidecar = read_file_bytes(sidecar_path)
    assert_equal(sidecar[0], UInt8(0x41))
    assert_equal(sidecar[1], UInt8(0x4B))
    assert_equal(sidecar[2], UInt8(0x48))
    assert_equal(sidecar[3], UInt8(0x47))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
