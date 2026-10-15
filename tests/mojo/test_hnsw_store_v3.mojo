from akasha.common.config import CollectionConfig
from akasha.index.hnsw import HnswIndex
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import ensure_directory, write_file_sync
from akasha.storage.hnsw_store import encode_hnsw_snapshot, decode_hnsw_snapshot_owned, open_hnsw_snapshot_view
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def _u64(bytes: List[UInt8], offset: Int) -> UInt64:
    var value = UInt64(0)
    for index in range(8):
        value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
    return value


def _u32(bytes: List[UInt8], offset: Int) -> UInt32:
    var value = UInt32(0)
    for index in range(4):
        value |= UInt32(bytes[offset + index]) << UInt32(index * 8)
    return value


def _put(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for index in range(4):
        bytes[offset + index] = UInt8(value >> UInt32(index * 8))


def _reject(mut bytes: List[UInt8], config: CollectionConfig, label: String) raises:
    _put(bytes, len(bytes) - 4, crc32_range(bytes, 0, len(bytes) - 4))
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(7))
    ensure_directory("/tmp/akasha-hnsw-v3")
    var path = String("/tmp/akasha-hnsw-v3/", label, ".bin")
    write_file_sync(path, bytes)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, UInt64(7))


def test_entry_pool_round_trips_owned_and_mapped() raises:
    var config = CollectionConfig.defaults(2)
    var index = HnswIndex(config)
    for id in range(120):
        index.add(id, [Float32(id), Float32(id % 7)])
    _ = index.delete(index.entry_point_id())
    var bytes = encode_hnsw_snapshot(index, UInt64(7))
    assert_equal(bytes[4], UInt8(3))
    var owned = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(7))
    assert_equal(owned.entries.primary, index.entries.primary)
    assert_equal(len(owned.entries.extra), len(index.entries.extra))
    assert_equal(encode_hnsw_snapshot(owned, UInt64(7)), bytes)
    ensure_directory("/tmp/akasha-hnsw-v3")
    var path = String("/tmp/akasha-hnsw-v3/roundtrip.bin")
    write_file_sync(path, bytes)
    var mapped = open_hnsw_snapshot_view(path, config, UInt64(7))
    assert_equal(mapped.entries.primary, index.entries.primary)
    assert_equal(len(mapped.entries.extra), len(index.entries.extra))
    var expected = index.search([33.0, 5.0], 5)
    var actual = mapped.search([33.0, 5.0], 5)
    assert_equal(len(expected), len(actual))
    for i in range(len(expected)):
        assert_equal(expected[i].id, actual[i].id)
        assert_equal(expected[i].score, actual[i].score)


def test_crc_valid_entry_corruption_rejected_by_both_readers() raises:
    var config = CollectionConfig.defaults(2)
    var index = HnswIndex(config)
    for id in range(8):
        index.add(id, [Float32(id), 1.0])
    var bytes = encode_hnsw_snapshot(index, UInt64(7))
    var offset = Int(_u64(bytes, 176))
    var bad = bytes.copy()
    _put(bad, offset, UInt32.MAX)
    _reject(bad, config, "count")
    bad = bytes.copy()
    _put(bad, offset + 8, UInt32(0))
    _reject(bad, config, "capacity")
    bad = bytes.copy()
    _put(bad, offset + 12, UInt32(1))
    _reject(bad, config, "reserved")
    bad = bytes.copy()
    _put(bad, offset + 16, UInt32(8))
    _reject(bad, config, "slot")
    bad = bytes.copy()
    _put(bad, offset + 20, UInt32.MAX)
    _reject(bad, config, "level")
    bad = bytes.copy()
    assert_true(_u32(bytes, offset + 4) > 0)
    _put(bad, offset + 24, _u32(bytes, offset + 16))
    _reject(bad, config, "duplicate")
    bad = bytes.copy()
    _put(bad, 176, UInt32(0))
    _reject(bad, config, "missing")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
