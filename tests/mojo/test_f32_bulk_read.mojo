from akasha.storage.checksum import (
    BinaryReader,
    BorrowedBinaryReader,
    BinaryWriter,
)
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def test_raw_f32_bits_alignments_and_owned_results() raises:
    var patterns: List[UInt32] = [
        0,
        0x80000000,
        0x00000001,
        0x007FFFFF,
        0x00800000,
        0x3F800000,
        0xBF800000,
        0x7F7FFFFF,
        0xFF7FFFFF,
        0x7F800000,
        0xFF800000,
        0x7FC00001,
        0x7F800001,
        0xFFFFFFFF,
    ]
    for prefix in range(8):
        for count in [0, 1, 3, 16, 17, 1536]:
            var writer = BinaryWriter()
            for _ in range(prefix):
                writer.write_u8(0xAA)
            for i in range(count):
                writer.write_u32(patterns[i % len(patterns)])
            writer.write_u8(0xCD)
            var bytes = writer.take_bytes()
            var reader = BinaryReader(bytes.copy())
            var borrowed = BorrowedBinaryReader(Span(bytes))
            for _ in range(prefix):
                assert_equal(reader.read_u8(), UInt8(0xAA))
                assert_equal(borrowed.read_u8(), UInt8(0xAA))
            var values = reader.read_f32s(count)
            var borrowed_values = borrowed.read_f32s(count)
            assert_equal(reader.position(), prefix + count * 4)
            assert_equal(borrowed.position(), prefix + count * 4)
            assert_equal(reader.read_u8(), UInt8(0xCD))
            assert_equal(borrowed.read_u8(), UInt8(0xCD))
            assert_equal(len(reader.read_f32s(0)), 0)
            assert_equal(len(borrowed.read_f32s(0)), 0)
            # The returned values remain owned after the byte source changes.
            for i in range(len(bytes)):
                bytes[i] = 0
            assert_equal(len(values), count)
            assert_equal(len(borrowed_values), count)
            for i in range(count):
                assert_equal(
                    bitcast[DType.uint32](values[i]),
                    patterns[i % len(patterns)],
                )
                assert_equal(
                    bitcast[DType.uint32](borrowed_values[i]),
                    patterns[i % len(patterns)],
                )


def test_truncation_and_overflow_leave_position_unchanged() raises:
    for size in range(65):
        var bytes = List[UInt8](length=size + 1, fill=0)
        var reader = BinaryReader(bytes.copy())
        var borrowed = BorrowedBinaryReader(Span(bytes))
        _ = reader.read_u8()
        _ = borrowed.read_u8()
        for count in [-1, Int.MIN, Int.MAX, size // 4 + 1]:
            with assert_raises():
                _ = reader.read_f32s(count)
            with assert_raises():
                _ = borrowed.read_f32s(count)
            assert_equal(reader.position(), 1)
            assert_equal(borrowed.position(), 1)
        var a = reader.read_f32s(size // 4)
        var b = borrowed.read_f32s(size // 4)
        assert_equal(len(a), size // 4)
        assert_equal(len(b), size // 4)
        assert_equal(reader.remaining(), size % 4)
        assert_equal(borrowed.remaining(), size % 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
