from akasha.storage.checksum import BinaryReader, BinaryWriter, crc32
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    TestSuite,
)


def test_crc32_matches_standard_check_value() raises:
    var data: List[UInt8] = [
        0x31,
        0x32,
        0x33,
        0x34,
        0x35,
        0x36,
        0x37,
        0x38,
        0x39,
    ]

    assert_equal(crc32(data), UInt32(0xCBF43926))


def test_binary_codec_round_trips_little_endian_values() raises:
    var writer = BinaryWriter()
    writer.write_u8(0xAB)
    writer.write_u16(0x1234)
    writer.write_u32(0x89ABCDEF)
    writer.write_u64(0x0123456789ABCDEF)
    writer.write_i64(-123456789)
    writer.write_f32(-3.25)
    var bytes = writer.take_bytes()

    assert_equal(bytes[1], UInt8(0x34))
    assert_equal(bytes[2], UInt8(0x12))

    var reader = BinaryReader(bytes^)
    assert_equal(reader.read_u8(), UInt8(0xAB))
    assert_equal(reader.read_u16(), UInt16(0x1234))
    assert_equal(reader.read_u32(), UInt32(0x89ABCDEF))
    assert_equal(reader.read_u64(), UInt64(0x0123456789ABCDEF))
    assert_equal(reader.read_i64(), Int64(-123456789))
    assert_almost_equal(reader.read_f32(), -3.25, atol=1.0e-6)
    assert_equal(reader.remaining(), 0)


def test_binary_reader_rejects_truncated_value() raises:
    var bytes: List[UInt8] = [0x01, 0x02, 0x03]
    var reader = BinaryReader(bytes^)

    with assert_raises():
        _ = reader.read_u32()


def test_binary_writer_bulk_append_copies_ordered_chunks() raises:
    var writer = BinaryWriter()
    var empty = List[UInt8]()
    var small: List[UInt8] = [1, 2, 3]
    var large = List[UInt8](capacity=16_387)
    for index in range(16_387):
        large.append(UInt8((index * 17 + 31) % 256))
    writer.write_bytes(empty)
    writer.write_u16(0xCAFE)
    writer.write_bytes(small)
    writer.write_bytes(large)
    writer.write_bytes(empty)
    writer.write_bytes(small)
    small[0] = 99
    large[0] = 99
    large.clear()
    var bytes = writer.take_bytes()
    assert_equal(len(bytes), 16_395)
    assert_equal(bytes[0], UInt8(0xFE))
    assert_equal(bytes[1], UInt8(0xCA))
    for index in range(3):
        assert_equal(bytes[index + 2], UInt8(index + 1))
        assert_equal(bytes[16_392 + index], UInt8(index + 1))
    for index in range(16_387):
        assert_equal(bytes[index + 5], UInt8((index * 17 + 31) % 256))


def test_binary_writer_can_reuse_taken_bytes_without_aliasing() raises:
    var writer = BinaryWriter()
    assert_equal(len(writer.take_bytes()), 0)
    var source: List[UInt8] = [0, 127, 128, 255]
    writer.write_bytes(source)
    var first = writer.take_bytes()
    assert_equal(len(writer.take_bytes()), 0)
    writer.write_u8(42)
    writer.write_bytes(first)
    first[0] = 99
    source.clear()
    var second = writer.take_bytes()
    var expected: List[UInt8] = [42, 0, 127, 128, 255]
    assert_equal(second, expected)
    assert_equal(len(writer.take_bytes()), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
