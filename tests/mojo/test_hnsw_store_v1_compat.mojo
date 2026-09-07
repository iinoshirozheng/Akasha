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
    decode_hnsw_snapshot_owned,
    encode_hnsw_snapshot,
    open_hnsw_snapshot_view,
)
from std.testing import assert_almost_equal, assert_equal, assert_raises, assert_true, TestSuite


comptime _EMPTY_FIXTURE = "tests/fixtures/hnsw-v1-empty.bin"
comptime _GRAPH_FIXTURE = "tests/fixtures/hnsw-v1-edges-tombstones.bin"


def _config() -> CollectionConfig:
    var config = CollectionConfig.defaults(2)
    config.ann_metric = MetricKind.l2()
    config.scalar_kind = ScalarKind.f32()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 128
    config.max_level = 4
    config.level_seed = UInt64(0x17A5A17A5)
    return config^


def _graph(config: CollectionConfig) raises -> HnswIndex:
    var graph = HnswIndex(config)
    for id in range(8):
        graph.add(
            id + 1,
            [Float32((id * 17) % 29) * 0.1, Float32((id * 11 + 3) % 31) * 0.1],
        )
    graph.upsert(3, [9.0, 1.0])
    assert_true(graph.delete(5))
    return graph^


def _put_u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for index in range(4):
        bytes[offset + index] = UInt8(value >> UInt32(index * 8))


def _put_u64(mut bytes: List[UInt8], offset: Int, value: UInt64):
    for index in range(8):
        bytes[offset + index] = UInt8(value >> UInt64(index * 8))


def _seal(mut bytes: List[UInt8]):
    var checksum_offset = len(bytes) - 4
    _put_u32(bytes, checksum_offset, crc32_range(bytes, 0, checksum_offset))


def test_frozen_v1_empty_and_history_fixtures_are_byte_exact() raises:
    var config = _config()
    var empty = HnswIndex(config)
    assert_equal(
        encode_hnsw_snapshot(empty, UInt64(76)),
        read_file_bytes(_EMPTY_FIXTURE),
    )
    var graph = _graph(config)
    assert_equal(
        encode_hnsw_snapshot(graph, UInt64(77)),
        read_file_bytes(_GRAPH_FIXTURE),
    )


def test_frozen_v1_fixtures_support_owned_and_mapped_queries() raises:
    var config = _config()
    var empty = decode_hnsw_snapshot_owned(
        read_file_bytes(_EMPTY_FIXTURE), config, UInt64(76)
    )
    assert_equal(empty.point_count(), 0)
    var mapped_empty = open_hnsw_snapshot_view(
        _EMPTY_FIXTURE, config, UInt64(76)
    )
    assert_equal(mapped_empty.slot_count(), 0)
    mapped_empty.close()

    var original = _graph(config)
    var expected = original.search([0.7, 1.3], 5, ef_search=32)
    var owned = decode_hnsw_snapshot_owned(
        read_file_bytes(_GRAPH_FIXTURE), config, UInt64(77)
    )
    var actual_owned = owned.search([0.7, 1.3], 5, ef_search=32)
    var mapped = open_hnsw_snapshot_view(
        _GRAPH_FIXTURE, config, UInt64(77)
    )
    var actual_mapped = mapped.search([0.7, 1.3], 5, ef_search=32)
    assert_equal(len(actual_owned), len(expected))
    assert_equal(len(actual_mapped), len(expected))
    for index in range(len(expected)):
        assert_equal(actual_owned[index].id, expected[index].id)
        assert_equal(actual_mapped[index].id, expected[index].id)
        assert_almost_equal(actual_owned[index].score, expected[index].score, atol=1.0e-6)
        assert_almost_equal(actual_mapped[index].score, expected[index].score, atol=1.0e-6)
    mapped.close()


def test_crc_valid_v1_non_f32_tags_are_rejected_owned_and_mapped() raises:
    var directory = String("/tmp/akasha-hnsw-v1-non-f32")
    ensure_directory(directory)
    var scalar_kinds: List[ScalarKind] = [
        ScalarKind.bf16(), ScalarKind.f16(), ScalarKind.i8()
    ]
    for scalar in scalar_kinds:
        var config = _config()
        config.ann_metric = MetricKind.dot()
        config.scalar_kind = scalar.copy()
        var bytes = read_file_bytes(_EMPTY_FIXTURE)
        _put_u64(bytes, 16, config.fingerprint())
        bytes[36] = config.ann_metric.tag()
        bytes[37] = scalar.tag()
        _seal(bytes)
        with assert_raises():
            _ = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(76))
        var path = directory + "/" + scalar.name() + ".bin"
        remove_file_if_exists(path)
        write_file_sync(path, bytes)
        with assert_raises():
            _ = open_hnsw_snapshot_view(path, config, UInt64(76))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
