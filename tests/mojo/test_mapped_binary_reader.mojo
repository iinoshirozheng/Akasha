from akasha.storage.checksum import BinaryWriter
from akasha.storage.filesystem import write_file_sync
from akasha.storage.mapped_file import MappedFile
from akasha.storage.mapped_reader import MappedBinaryReader
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def test_mapped_reader_preserves_unaligned_scalars_and_owned_float_bits() raises:
    var writer = BinaryWriter()
    writer.write_u8(0xAB)
    writer.write_u16(0x1234)
    writer.write_u32(0x89ABCDEF)
    writer.write_u64(UInt64.MAX)
    writer.write_i64(Int64.MIN)
    var bits: List[UInt32] = [
        0,
        0x80000000,
        0x3F800000,
        0x7F800000,
        0xFF800000,
        0x7FC01234,
        0x00000001,
    ]
    for value in bits:
        writer.write_u32(value)
    writer.write_bytes([UInt8(97), UInt8(98), UInt8(255)])
    var path = String("/tmp/akasha-mapped-reader-bits.bin")
    write_file_sync(path, writer.take_bytes())
    var mapping = MappedFile.open_readonly(path)
    var reader = MappedBinaryReader(Pointer(to=mapping).as_imm())
    assert_equal(reader.read_u8(), UInt8(0xAB))
    assert_equal(reader.read_u16(), UInt16(0x1234))
    assert_equal(reader.read_u32(), UInt32(0x89ABCDEF))
    assert_equal(reader.read_u64(), UInt64.MAX)
    assert_equal(reader.read_i64(), Int64.MIN)
    var values = reader.read_f32s(len(bits))
    var tail = reader.read_bytes(3)
    assert_equal(reader.remaining(), 0)
    assert_equal(len(reader.read_f32s(0)), 0)
    assert_equal(len(reader.read_bytes(0)), 0)
    mapping.close()
    for index in range(len(bits)):
        assert_equal(bitcast[DType.uint32](values[index]), bits[index])
    assert_equal(tail[2], UInt8(255))
    with assert_raises():
        _ = reader.read_bytes(0)


def test_mapped_reader_bounds_never_advance_or_allocate_invalid_counts() raises:
    var path = String("/tmp/akasha-mapped-reader-bounds.bin")
    write_file_sync(path, [UInt8(1), UInt8(2), UInt8(3), UInt8(4)])
    var mapping = MappedFile.open_readonly(path)
    var reader = MappedBinaryReader(Pointer(to=mapping).as_imm())
    assert_equal(reader.read_u8(), UInt8(1))
    for count in [-1, 4, Int.MAX]:
        with assert_raises():
            _ = reader.read_bytes(count)
        assert_equal(reader.position(), 1)
        with assert_raises():
            _ = reader.read_f32s(count)
        assert_equal(reader.position(), 1)
    with assert_raises():
        _ = reader.read_u64()
    assert_equal(reader.position(), 1)
    assert_equal(reader.read_u16(), UInt16(0x0302))
    assert_equal(reader.read_u8(), UInt8(4))
    with assert_raises():
        _ = reader.read_u8()
    assert_equal(reader.position(), 4)
    mapping.close()
    with assert_raises():
        _ = reader.read_f32s(0)


def test_empty_mapped_reader_has_no_data_pointer_to_dereference() raises:
    var path = String("/tmp/akasha-mapped-reader-empty.bin")
    write_file_sync(path, List[UInt8]())
    var mapping = MappedFile.open_readonly(path)
    var reader = MappedBinaryReader(Pointer(to=mapping).as_imm())
    assert_equal(reader.remaining(), 0)
    assert_equal(len(reader.read_bytes(0)), 0)
    assert_equal(len(reader.read_f32s(0)), 0)
    with assert_raises():
        _ = reader.read_u8()
    assert_equal(reader.position(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
