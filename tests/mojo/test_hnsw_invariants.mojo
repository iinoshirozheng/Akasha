from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_level import sample_level
from akasha.storage.checksum import BinaryWriter
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _config(ef_construction: Int = 24) -> CollectionConfig:
    var config = CollectionConfig.defaults(3)
    config.ann_metric = MetricKind.l2()
    config.m = 4
    config.m0 = 8
    config.ef_construction = ef_construction
    config.default_ef_search = 16
    config.max_ef_search = 128
    config.max_level = 12
    config.level_seed = UInt64(0x0DDC0FFEE1234567)
    return config^


def _point(id: Int) -> List[Float32]:
    var values: List[Float32] = [
        Float32((id * 17) % 101) * 0.01,
        Float32((id * 29 + 7) % 103) * 0.01,
        Float32((id * 43 + 11) % 107) * 0.01,
    ]
    return values^


def test_seeded_insertions_use_geometric_levels_and_stay_valid() raises:
    var config = _config()
    var index = HnswIndex(config.copy())
    var expected_entry_level = -1
    var expected_entry_id = -1

    for id in range(1, 201):
        var values = _point(id)
        index.add(id, values^)
        var expected_level = sample_level(
            id, config.level_seed, config.m, config.max_level
        )
        var slot = index.graph.current_slot(id).value()
        assert_equal(index.graph.level(slot), expected_level)
        if expected_level > expected_entry_level:
            expected_entry_level = expected_level
            expected_entry_id = id
        assert_equal(index.entry_point_level(), expected_entry_level)
        assert_equal(index.entry_point_id(), expected_entry_id)
        index.validate_structure()

    assert_equal(index.point_count(), 200)
    assert_true(index.maximum_neighbor_count(0) <= config.m0)
    assert_true(index.maximum_upper_neighbor_count() <= config.m)
    assert_equal(index.build_slot_count(), 200)
    assert_true(index.build_distance_evaluations() > 0)


def test_ef_construction_changes_recorded_work() raises:
    var low_config = _config(8)
    var high_config = _config(48)
    var low = HnswIndex(low_config.copy())
    var high = HnswIndex(high_config.copy())
    for id in range(1, 121):
        var low_values = _point(id)
        var high_values = _point(id)
        low.add(id, low_values^)
        high.add(id, high_values^)

    assert_true(
        high.build_distance_evaluations()
        > low.build_distance_evaluations()
    )


def test_public_search_stats_are_not_polluted_by_construction() raises:
    var index = HnswIndex(_config())
    for id in range(1, 81):
        var values = _point(id)
        index.add(id, values^)

    assert_equal(index.last_search_distance_evaluations(), 0)
    var query = _point(37)
    _ = index.search(query^, 5, ef_search=24)
    assert_true(index.last_search_distance_evaluations() > 0)
    assert_true(index.last_search_visited() < index.point_count())
    assert_equal(index.last_search_effective_ef(), 24)


def _legacy_cache_fixture() -> List[UInt8]:
    # Prototype layout: m, max_level, count, entry slot/level, followed by
    # node headers, raw vectors, then per-level neighbor ordinals.
    var writer = BinaryWriter()
    writer.write_u16(UInt16(2))
    writer.write_u16(UInt16(4))
    writer.write_u32(UInt32(2))
    writer.write_i64(Int64(0))
    writer.write_i64(Int64(1))

    writer.write_i64(Int64(10))
    writer.write_u16(UInt16(1))
    writer.write_u16(UInt16(0))
    writer.write_f32(1.0)
    writer.write_u16(UInt16(1))
    writer.write_u16(UInt16(0))
    writer.write_u32(UInt32(1))
    writer.write_u16(UInt16(0))
    writer.write_u16(UInt16(0))

    writer.write_i64(Int64(20))
    writer.write_u16(UInt16(0))
    writer.write_u16(UInt16(0))
    writer.write_f32(2.0)
    writer.write_u16(UInt16(1))
    writer.write_u16(UInt16(0))
    writer.write_u32(UInt32(0))
    return writer.take_bytes()


def test_legacy_cache_fixture_round_trips_byte_for_byte() raises:
    var fixture = _legacy_cache_fixture()
    var expected = fixture.copy()
    var index = HnswIndex.decode_cache_payload(1, fixture^)
    var encoded = index.encode_cache_payload()

    assert_equal(len(encoded), len(expected))
    for offset in range(len(expected)):
        assert_equal(encoded[offset], expected[offset])
    assert_equal(index.search_l2([1.1], 1, 8)[0].id, 10)
    index.validate_structure()


def test_legacy_cache_accepts_prototype_m_one_and_zero_max_level() raises:
    var writer = BinaryWriter()
    writer.write_u16(UInt16(1))
    writer.write_u16(UInt16(0))
    writer.write_u32(UInt32(1))
    writer.write_i64(Int64(0))
    writer.write_i64(Int64(0))
    writer.write_i64(Int64(7))
    writer.write_u16(UInt16(0))
    writer.write_u16(UInt16(0))
    writer.write_f32(3.0)
    writer.write_u16(UInt16(0))
    writer.write_u16(UInt16(0))
    var fixture = writer.take_bytes()
    var expected = fixture.copy()

    var index = HnswIndex.decode_cache_payload(1, fixture^)
    var encoded = index.encode_cache_payload()
    assert_equal(len(encoded), len(expected))
    for offset in range(len(expected)):
        assert_equal(encoded[offset], expected[offset])
    assert_equal(index.search_l2([3.0], 1, 1)[0].id, 7)


def _decode_error(var payload: List[UInt8]) -> String:
    try:
        _ = HnswIndex.decode_cache_payload(1, payload^)
    except error:
        return String(error)
    return ""


def test_cache_preflight_rejects_maximum_degree_allocation_amplification() raises:
    var writer = BinaryWriter()
    writer.write_u16(UInt16.MAX)
    writer.write_u16(UInt16(1))
    writer.write_u32(UInt32(1))
    writer.write_i64(Int64(0))
    writer.write_i64(Int64(0))
    writer.write_i64(Int64(7))
    writer.write_u16(UInt16(0))
    writer.write_u16(UInt16(0))
    writer.write_f32(3.0)
    writer.write_u16(UInt16(0))
    writer.write_u16(UInt16(0))
    var payload = writer.take_bytes()

    assert_equal(
        _decode_error(payload^),
        "HNSW cache estimated allocation exceeds amplification limit",
    )


def test_cache_preflight_rejects_maximum_level_before_append() raises:
    var writer = BinaryWriter()
    writer.write_u16(UInt16(1))
    writer.write_u16(UInt16.MAX)
    writer.write_u32(UInt32(1))
    writer.write_i64(Int64(0))
    writer.write_i64(Int64(Int(UInt16.MAX)))
    writer.write_i64(Int64(7))
    writer.write_u16(UInt16.MAX)
    writer.write_u16(UInt16(0))
    writer.write_f32(3.0)
    # Deliberately omit 65,536 level headers: preflight must reject the
    # estimated packed allocation instead of appending and then seeing EOF.
    var payload = writer.take_bytes()

    assert_equal(
        _decode_error(payload^),
        "HNSW cache estimated allocation exceeds amplification limit",
    )


def _two_node_cache(
    first_level: Int,
    second_level: Int,
    entry_index: Int,
    first_level_zero: List[UInt32],
    first_level_one: List[UInt32],
    second_level_zero: List[UInt32],
) -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_u16(UInt16(4))
    writer.write_u16(UInt16(4))
    writer.write_u32(UInt32(2))
    writer.write_i64(Int64(entry_index))
    var entry_level = first_level if entry_index == 0 else second_level
    writer.write_i64(Int64(entry_level))
    writer.write_i64(Int64(10))
    writer.write_u16(UInt16(first_level))
    writer.write_u16(UInt16(0))
    writer.write_f32(1.0)
    writer.write_u16(UInt16(len(first_level_zero)))
    writer.write_u16(UInt16(0))
    for neighbor in first_level_zero:
        writer.write_u32(neighbor)
    if first_level > 0:
        writer.write_u16(UInt16(len(first_level_one)))
        writer.write_u16(UInt16(0))
        for neighbor in first_level_one:
            writer.write_u32(neighbor)
    writer.write_i64(Int64(20))
    writer.write_u16(UInt16(second_level))
    writer.write_u16(UInt16(0))
    writer.write_f32(2.0)
    writer.write_u16(UInt16(len(second_level_zero)))
    writer.write_u16(UInt16(0))
    for neighbor in second_level_zero:
        writer.write_u32(neighbor)
    if second_level > 0:
        writer.write_u16(UInt16(0))
        writer.write_u16(UInt16(0))
    return writer.take_bytes()


def test_cache_rejects_asymmetry_and_target_level_mismatch() raises:
    var one: List[UInt32] = [UInt32(1)]
    var none = List[UInt32]()
    var asymmetric = _two_node_cache(0, 0, 0, one, none, none)
    assert_equal(
        _decode_error(asymmetric^),
        "HNSW graph contains an asymmetric edge",
    )

    var upper: List[UInt32] = [UInt32(1)]
    var reciprocal: List[UInt32] = [UInt32(0)]
    var wrong_level = _two_node_cache(
        1, 0, 0, one, upper, reciprocal
    )
    assert_equal(
        _decode_error(wrong_level^),
        "HNSW edge target does not own graph level",
    )


def test_cache_rejects_nonhighest_entry_duplicate_and_self_edges() raises:
    var none = List[UInt32]()
    var nonhighest = _two_node_cache(0, 1, 0, none, none, none)
    assert_equal(
        _decode_error(nonhighest^),
        "HNSW cache entry point is not on the highest graph level",
    )

    var duplicates: List[UInt32] = [UInt32(1), UInt32(1)]
    var reciprocal: List[UInt32] = [UInt32(0)]
    var duplicate = _two_node_cache(
        0, 0, 0, duplicates, none, reciprocal
    )
    assert_equal(
        _decode_error(duplicate^),
        "HNSW cache neighbor list contains a duplicate",
    )

    var self_edge: List[UInt32] = [UInt32(0)]
    var self_payload = _two_node_cache(
        0, 0, 0, self_edge, none, none
    )
    assert_equal(
        _decode_error(self_payload^),
        "HNSW cache self edges are not allowed",
    )


def test_config_mutation_is_rejected_before_append_without_quarantine() raises:
    var config = _config()
    var index = HnswIndex(config)
    var first = _point(1)
    index.add(1, first^)
    var before_distances = index.build_distance_evaluations()
    index.config.m = 5

    var second = _point(2)
    with assert_raises():
        index.add(2, second^)
    assert_equal(index.point_count(), 1)
    assert_equal(index.build_distance_evaluations(), before_distances)
    assert_true(index.valid)
    assert_true(index.graph.is_valid())


def test_post_append_internal_failure_quarantines_and_preserves_stats() raises:
    var index = HnswIndex(_config())
    for id in range(1, 4):
        var values = _point(id)
        index.add(id, values^)
    var entry = index.entry_slot.value()
    assert_true(index.graph.neighbor_count(entry, 0) > 0)
    index.graph.neighbor_slots[index.graph.neighbor_bases[Int(entry)]] = (
        UInt32(999)
    )
    var before_slots = index.build_stats.slot_count
    var before_edges = index.build_stats.directed_edges
    var before_distances = index.build_stats.distance_evaluations
    var before_maximum = index.build_stats.maximum_level

    var next = _point(4)
    with assert_raises():
        index.add(4, next^)

    assert_false(index.valid)
    assert_false(index.graph.is_valid())
    assert_equal(index.build_stats.slot_count, before_slots)
    assert_equal(index.build_stats.directed_edges, before_edges)
    assert_equal(index.build_stats.distance_evaluations, before_distances)
    assert_equal(index.build_stats.maximum_level, before_maximum)
    with assert_raises():
        var query = _point(1)
        _ = index.search(query^, 1, ef_search=8)


def test_nonlegacy_identity_cannot_use_lossy_cache_codec() raises:
    var dot_config = _config()
    dot_config.ann_metric = MetricKind.dot()
    var dot = HnswIndex(dot_config)
    var dot_point = _point(1)
    dot.add(1, dot_point^)
    with assert_raises():
        _ = dot.encode_cache_payload()

    var m0_config = _config()
    var m0 = HnswIndex(m0_config)
    var m0_point = _point(1)
    m0.add(1, m0_point^)
    with assert_raises():
        _ = m0.encode_cache_payload()


def test_legacy_initializer_supports_old_bounded_configuration_range() raises:
    var minimum = HnswIndex(1, m=1, max_level=0)
    minimum.add(1, [1.0])
    assert_equal(minimum.search_l2([1.0], 1, 1)[0].id, 1)

    var wide_level = HnswIndex(1, m=2, max_level=65_535)
    wide_level.add(1, [1.0])
    assert_equal(wide_level.search_l2([1.0], 1, 1)[0].id, 1)

    var wide_m = HnswIndex(1, m=65_535, max_level=0)
    wide_m.add(1, [1.0])
    assert_equal(wide_m.search_l2([1.0], 1, 1)[0].id, 1)

    with assert_raises():
        _ = HnswIndex(1, m=65_536, max_level=0)
    with assert_raises():
        _ = HnswIndex(1, m=1, max_level=65_536)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
