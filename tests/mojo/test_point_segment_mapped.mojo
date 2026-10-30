from akasha.storage.filesystem import read_file_bytes, write_file_sync, remove_file_if_exists
from akasha.storage.point_segment import decode_point_segment, encode_point_segment, read_point_segment
from akasha.document.point_state import PointField, PointState
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from test_field_envelopes import _catalog, _fixture, _crc, _u32, _u64
from std.testing import assert_equal, assert_raises, TestSuite


def test_mapped_point_segments_preserve_frozen_and_current_owned_values() raises:
    var path = String("/tmp/akasha-point-segment-mapped-valid.bin")
    var names: List[String] = ["base-v4.bin", "delta-v4.bin", "typed-base-v4.bin", "empty-base-v4.bin"]
    for index in range(len(names)):
        var catalog = _catalog(index >= 2)
        var bytes = _fixture(names[index])
        for version in [4, 5]:
            bytes[4] = UInt8(version)
            _crc(bytes)
            write_file_sync(path, bytes)
            var actual = read_point_segment(path, catalog)
            assert_equal(actual.checksum, decode_point_segment(bytes, catalog).checksum)
            assert_equal(read_file_bytes(path), bytes)
            # The mapping has returned/closed. Removing/replacing its inode must
            # not affect the independently owned decoded fields or payload.
            remove_file_if_exists(path)
            write_file_sync(path, [UInt8(0)])
            var expected = bytes.copy()
            expected[4] = 5
            _crc(expected)
            assert_equal(encode_point_segment(actual.kind, actual.min_sequence,
                actual.last_sequence, actual.points, catalog, payload_version=1), expected)
    remove_file_if_exists(path)


def test_mapped_point_segments_reject_torn_corrupt_and_trailing_files() raises:
    var path = String("/tmp/akasha-point-segment-mapped-corrupt.bin")
    var names: List[String] = ["base-v4.bin", "delta-v4.bin", "typed-base-v4.bin", "empty-base-v4.bin"]
    for index in range(len(names)):
        var catalog = _catalog(index >= 2)
        var original = _fixture(names[index])
        for count in range(len(original)):
            var truncated = List[UInt8]()
            truncated.extend(Span(original)[:count])
            write_file_sync(path, truncated)
            with assert_raises():
                _ = read_point_segment(path, catalog)
        for offset in range(len(original)):
            var bytes = original.copy()
            bytes[offset] ^= 1
            write_file_sync(path, bytes)
            with assert_raises():
                _ = read_point_segment(path, catalog)
        var trailing = original.copy()
        trailing.append(0)
        write_file_sync(path, trailing)
        with assert_raises():
            _ = read_point_segment(path, catalog)
    remove_file_if_exists(path)


def test_mapped_point_segments_reject_crc_valid_invalid_lengths_and_headers() raises:
    var path = String("/tmp/akasha-point-segment-mapped-invalid.bin")
    var catalog = _catalog()
    for offset in [4, 6, 8, 16, 20, 24, 32, 48, 52, 53, 54]:
        var bytes = _fixture("base-v4.bin")
        bytes[offset] = 255
        _crc(bytes)
        write_file_sync(path, bytes)
        with assert_raises():
            _ = decode_point_segment(bytes, catalog)
        with assert_raises():
            _ = read_point_segment(path, catalog)
    for size in [0, 39, 268435457, Int(UInt32.MAX)]:
        var bytes = _fixture("base-v4.bin")
        _u32(bytes, 48, UInt32(size))
        _crc(bytes)
        write_file_sync(path, bytes)
        with assert_raises():
            _ = read_point_segment(path, catalog)
    var bytes = _fixture("base-v4.bin")
    _u64(bytes, 24, UInt64.MAX)
    _crc(bytes)
    write_file_sync(path, bytes)
    with assert_raises():
        _ = read_point_segment(path, catalog)
    bytes = _fixture("base-v4.bin")
    _u64(bytes, 40, 0)
    _crc(bytes)
    write_file_sync(path, bytes)
    with assert_raises():
        _ = decode_point_segment(bytes, catalog)
    with assert_raises():
        _ = read_point_segment(path, catalog)
    remove_file_if_exists(path)


def test_mapped_sparse_zero_weights_remain_version_gated() raises:
    var path = String("/tmp/akasha-point-segment-mapped-zero.bin")
    var catalog = _catalog()
    var points: List[PointState] = [PointState.live(
        7, 8, 0, [PointField(1, VectorValue.sparse([SparseElement(9, 0)]))], []
    )]
    var bytes = encode_point_segment(1, 0, 8, points, catalog)
    write_file_sync(path, bytes)
    var decoded = read_point_segment(path, catalog)
    assert_equal(decoded.points[0].field_at(0).value().sparse_values()[0].weight, Float32(0))
    bytes[4] = 4
    _crc(bytes)
    write_file_sync(path, bytes)
    with assert_raises(contains="v4 sparse weights"):
        _ = read_point_segment(path, catalog)
    remove_file_if_exists(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
