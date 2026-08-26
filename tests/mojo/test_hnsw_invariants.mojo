from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_level import sample_level
from akasha.storage.checksum import BinaryWriter
from std.testing import assert_equal, assert_true, TestSuite


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
