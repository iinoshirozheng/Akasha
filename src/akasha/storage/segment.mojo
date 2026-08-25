from akasha.storage.checksum import (
    BinaryReader,
    BinaryWriter,
    crc32_range,
)
from akasha.storage.filesystem import read_file_bytes, write_file_sync
from akasha.storage.memtable import MemTableEntry


comptime _MAGIC_0 = UInt8(0x41)  # A
comptime _MAGIC_1 = UInt8(0x4B)  # K
comptime _MAGIC_2 = UInt8(0x53)  # S
comptime _MAGIC_3 = UInt8(0x47)  # G
comptime _VERSION = UInt16(1)
comptime _FIXED_SIZE = 32


struct SegmentSnapshot(Movable):
    """A decoded complete live-state snapshot."""

    var dimension: Int
    var last_sequence: UInt64
    var checksum: UInt32
    var entries: List[MemTableEntry]

    def __init__(
        out self,
        dimension: Int,
        last_sequence: UInt64,
        checksum: UInt32,
        var entries: List[MemTableEntry],
    ):
        self.dimension = dimension
        self.last_sequence = last_sequence
        self.checksum = checksum
        self.entries = entries^


def encode_segment(
    dimension: Int,
    last_sequence: UInt64,
    entries: List[MemTableEntry],
) raises -> List[UInt8]:
    if dimension <= 0:
        raise Error("segment dimension must be positive")
    if len(entries) > 0 and last_sequence == 0:
        raise Error("non-empty segment requires a sequence")

    var previous_id = 0
    for index in range(len(entries)):
        if entries[index].tombstone:
            raise Error("segment cannot contain tombstones")
        if len(entries[index].values) != dimension:
            raise Error("segment vector dimension mismatch")
        if (
            entries[index].sequence == 0
            or entries[index].sequence > last_sequence
        ):
            raise Error("invalid segment entry sequence")
        if index > 0 and entries[index].id <= previous_id:
            raise Error("segment point IDs must increase")
        previous_id = entries[index].id

    var writer = BinaryWriter()
    writer.write_u8(_MAGIC_0)
    writer.write_u8(_MAGIC_1)
    writer.write_u8(_MAGIC_2)
    writer.write_u8(_MAGIC_3)
    writer.write_u16(_VERSION)
    writer.write_u16(0)
    writer.write_u32(UInt32(dimension))
    writer.write_u64(UInt64(len(entries)))
    writer.write_u64(last_sequence)
    for index in range(len(entries)):
        writer.write_i64(Int64(entries[index].id))
        writer.write_u64(entries[index].sequence)
        for value in entries[index].values:
            writer.write_f32(value)

    var body = writer.take_bytes()
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def decode_segment_bytes(
    var bytes: List[UInt8], expected_dimension: Int
) raises -> SegmentSnapshot:
    if expected_dimension <= 0:
        raise Error("segment dimension must be positive")
    if len(bytes) < _FIXED_SIZE:
        raise Error("truncated segment")

    var encoded_size = len(bytes)
    var stored_checksum = UInt32(_read_u32_at(bytes, encoded_size - 4))
    if crc32_range(bytes, 4, encoded_size - 4) != stored_checksum:
        raise Error("segment checksum mismatch")

    var reader = BinaryReader(bytes^)
    if (
        reader.read_u8() != _MAGIC_0
        or reader.read_u8() != _MAGIC_1
        or reader.read_u8() != _MAGIC_2
        or reader.read_u8() != _MAGIC_3
    ):
        raise Error("invalid segment magic")
    if reader.read_u16() != _VERSION:
        raise Error("unsupported segment version")
    if reader.read_u16() != 0:
        raise Error("unsupported segment flags")
    var dimension = Int(reader.read_u32())
    if dimension != expected_dimension:
        raise Error("segment dimension mismatch")
    var record_count_u64 = reader.read_u64()
    if record_count_u64 > UInt64(Int.MAX):
        raise Error("segment record count is too large")
    var record_count = Int(record_count_u64)
    var last_sequence = reader.read_u64()
    var record_size = 16 + dimension * 4
    if _FIXED_SIZE + record_count * record_size != encoded_size:
        raise Error("segment length mismatch")
    if record_count > 0 and last_sequence == 0:
        raise Error("invalid segment sequence")

    var entries = List[MemTableEntry](capacity=record_count)
    var previous_id = 0
    for index in range(record_count):
        var id = Int(reader.read_i64())
        var sequence = reader.read_u64()
        if sequence == 0 or sequence > last_sequence:
            raise Error("invalid segment entry sequence")
        if index > 0 and id <= previous_id:
            raise Error("segment point IDs must increase")
        previous_id = id
        var values = List[Float32](capacity=dimension)
        for _ in range(dimension):
            values.append(reader.read_f32())
        entries.append(MemTableEntry(id, sequence, False, values^))

    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected segment payload")
    return SegmentSnapshot(dimension, last_sequence, stored_checksum, entries^)


def write_segment(
    path: String,
    dimension: Int,
    last_sequence: UInt64,
    entries: List[MemTableEntry],
) raises -> UInt32:
    var bytes = encode_segment(dimension, last_sequence, entries)
    var checksum = UInt32(_read_u32_at(bytes, len(bytes) - 4))
    write_file_sync(path, bytes)
    return checksum


def read_segment(path: String, dimension: Int) raises -> SegmentSnapshot:
    var bytes = read_file_bytes(path)
    return decode_segment_bytes(bytes^, dimension)


def _read_u32_at(bytes: List[UInt8], offset: Int) -> Int:
    return Int(
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )
