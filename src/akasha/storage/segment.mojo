from akasha.document.codec import decode_payload, encode_payload
from akasha.document.record import DocumentField
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
comptime _VERSION_V1 = UInt16(1)
comptime _VERSION_V2 = UInt16(2)
comptime _VERSION_V3 = UInt16(3)
comptime _FIXED_SIZE_LEGACY = 32
comptime _FIXED_SIZE_V3 = 40
comptime SEGMENT_KIND_BASE = 1
comptime SEGMENT_KIND_DELTA = 2


struct SegmentSnapshot(Movable):
    """A decoded immutable base or delta segment."""

    var dimension: Int
    var format_version: Int
    var kind: Int
    var min_sequence: UInt64
    var last_sequence: UInt64
    var checksum: UInt32
    var entries: List[MemTableEntry]

    def __init__(
        out self,
        dimension: Int,
        format_version: Int,
        kind: Int,
        min_sequence: UInt64,
        last_sequence: UInt64,
        checksum: UInt32,
        var entries: List[MemTableEntry],
    ):
        self.dimension = dimension
        self.format_version = format_version
        self.kind = kind
        self.min_sequence = min_sequence
        self.last_sequence = last_sequence
        self.checksum = checksum
        self.entries = entries^


def encode_segment(
    dimension: Int,
    last_sequence: UInt64,
    entries: List[MemTableEntry],
) raises -> List[UInt8]:
    """Encode the complete live-state v2 snapshot format."""
    if dimension <= 0:
        raise Error("segment dimension must be positive")
    if len(entries) > 0 and last_sequence == 0:
        raise Error("non-empty segment requires a sequence")
    _validate_entries(
        dimension,
        SEGMENT_KIND_BASE,
        0,
        last_sequence,
        entries,
    )

    var writer = BinaryWriter()
    _write_prefix(writer, _VERSION_V2, 0, dimension, len(entries))
    writer.write_u64(last_sequence)
    for index in range(len(entries)):
        writer.write_i64(Int64(entries[index].id))
        writer.write_u64(entries[index].sequence)
        _write_live_body(writer, entries[index])
    return _finish_segment(writer^)


def encode_segment_v3(
    dimension: Int,
    kind: Int,
    min_sequence: UInt64,
    max_sequence: UInt64,
    entries: List[MemTableEntry],
) raises -> List[UInt8]:
    if dimension <= 0:
        raise Error("segment dimension must be positive")
    if kind != SEGMENT_KIND_BASE and kind != SEGMENT_KIND_DELTA:
        raise Error("unsupported segment kind")
    if min_sequence > max_sequence:
        raise Error("segment sequence range is invalid")
    if len(entries) > 0 and max_sequence == 0:
        raise Error("non-empty segment requires a sequence")
    _validate_entries(dimension, kind, min_sequence, max_sequence, entries)

    var writer = BinaryWriter()
    _write_prefix(writer, _VERSION_V3, kind, dimension, len(entries))
    writer.write_u64(min_sequence)
    writer.write_u64(max_sequence)
    for index in range(len(entries)):
        writer.write_i64(Int64(entries[index].id))
        writer.write_u64(entries[index].sequence)
        if entries[index].tombstone:
            writer.write_u8(1)
            writer.write_u8(0)
            writer.write_u16(0)
        else:
            writer.write_u8(0)
            writer.write_u8(0)
            writer.write_u16(0)
            _write_live_body(writer, entries[index])
    return _finish_segment(writer^)


def decode_segment_bytes(
    var bytes: List[UInt8], expected_dimension: Int
) raises -> SegmentSnapshot:
    if expected_dimension <= 0:
        raise Error("segment dimension must be positive")
    if len(bytes) < _FIXED_SIZE_LEGACY:
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
    var version = reader.read_u16()
    if (
        version != _VERSION_V1
        and version != _VERSION_V2
        and version != _VERSION_V3
    ):
        raise Error("unsupported segment version")
    var kind_or_flags = Int(reader.read_u16())
    var kind = SEGMENT_KIND_BASE
    if version == _VERSION_V3:
        kind = kind_or_flags
        if kind != SEGMENT_KIND_BASE and kind != SEGMENT_KIND_DELTA:
            raise Error("unsupported segment kind")
        if encoded_size < _FIXED_SIZE_V3:
            raise Error("truncated segment")
    elif kind_or_flags != 0:
        raise Error("unsupported segment flags")

    var dimension = Int(reader.read_u32())
    if dimension != expected_dimension:
        raise Error("segment dimension mismatch")
    var record_count_u64 = reader.read_u64()
    if record_count_u64 > UInt64(Int.MAX):
        raise Error("segment record count is too large")
    var record_count = Int(record_count_u64)
    var min_sequence = UInt64(0)
    var last_sequence: UInt64
    if version == _VERSION_V3:
        min_sequence = reader.read_u64()
        last_sequence = reader.read_u64()
        if min_sequence > last_sequence:
            raise Error("segment sequence range is invalid")
        if record_count > (encoded_size - _FIXED_SIZE_V3) // 20:
            raise Error("segment record count exceeds file length")
    else:
        last_sequence = reader.read_u64()
        var v1_record_size = 16 + dimension * 4
        if version == _VERSION_V1:
            if (
                _FIXED_SIZE_LEGACY + record_count * v1_record_size
                != encoded_size
            ):
                raise Error("segment length mismatch")
        else:
            var minimum_record_size = 20 + dimension * 4
            if record_count_u64 > UInt64(
                (encoded_size - _FIXED_SIZE_LEGACY) // minimum_record_size
            ):
                raise Error("segment record count exceeds file length")
    if record_count > 0 and last_sequence == 0:
        raise Error("invalid segment sequence")

    var entries = List[MemTableEntry](capacity=record_count)
    var previous_id = 0
    for index in range(record_count):
        var id = Int(reader.read_i64())
        var sequence = reader.read_u64()
        if sequence == 0 or sequence < min_sequence or sequence > last_sequence:
            raise Error("invalid segment entry sequence")
        if index > 0 and id <= previous_id:
            raise Error("segment point IDs must increase")
        previous_id = id

        var tombstone = False
        if version == _VERSION_V3:
            var state = reader.read_u8()
            if state > 1:
                raise Error("unsupported segment record state")
            tombstone = state == 1
            if reader.read_u8() != 0 or reader.read_u16() != 0:
                raise Error("unsupported segment record flags")
            if tombstone and kind == SEGMENT_KIND_BASE:
                raise Error("base segment cannot contain tombstones")

        if tombstone:
            entries.append(MemTableEntry(id, sequence, True, List[Float32]()))
            continue

        var values = List[Float32](capacity=dimension)
        for _ in range(dimension):
            values.append(reader.read_f32())
        var fields = List[DocumentField]()
        if version != _VERSION_V1:
            var payload_length = Int(reader.read_u32())
            var payload = reader.read_bytes(payload_length)
            fields = decode_payload(payload^)
        entries.append(
            MemTableEntry.with_fields(id, sequence, False, values^, fields^)
        )

    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected segment payload")
    return SegmentSnapshot(
        dimension,
        Int(version),
        kind,
        min_sequence,
        last_sequence,
        stored_checksum,
        entries^,
    )


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


def write_segment_v3(
    path: String,
    dimension: Int,
    kind: Int,
    min_sequence: UInt64,
    max_sequence: UInt64,
    entries: List[MemTableEntry],
) raises -> UInt32:
    var bytes = encode_segment_v3(
        dimension, kind, min_sequence, max_sequence, entries
    )
    var checksum = UInt32(_read_u32_at(bytes, len(bytes) - 4))
    write_file_sync(path, bytes)
    return checksum


def read_segment(path: String, dimension: Int) raises -> SegmentSnapshot:
    var bytes = read_file_bytes(path)
    return decode_segment_bytes(bytes^, dimension)


def _validate_entries(
    dimension: Int,
    kind: Int,
    min_sequence: UInt64,
    max_sequence: UInt64,
    entries: List[MemTableEntry],
) raises:
    var previous_id = 0
    for index in range(len(entries)):
        if (
            entries[index].sequence == 0
            or entries[index].sequence < min_sequence
            or entries[index].sequence > max_sequence
        ):
            raise Error("invalid segment entry sequence")
        if index > 0 and entries[index].id <= previous_id:
            raise Error("segment point IDs must increase")
        previous_id = entries[index].id
        if entries[index].tombstone:
            if kind == SEGMENT_KIND_BASE:
                raise Error("base segment cannot contain tombstones")
            if (
                len(entries[index].values) != 0
                or len(entries[index].fields) != 0
            ):
                raise Error("segment tombstone must not contain a value")
        elif len(entries[index].values) != dimension:
            raise Error("segment vector dimension mismatch")


def _write_prefix(
    mut writer: BinaryWriter,
    version: UInt16,
    kind_or_flags: Int,
    dimension: Int,
    record_count: Int,
):
    writer.write_u8(_MAGIC_0)
    writer.write_u8(_MAGIC_1)
    writer.write_u8(_MAGIC_2)
    writer.write_u8(_MAGIC_3)
    writer.write_u16(version)
    writer.write_u16(UInt16(kind_or_flags))
    writer.write_u32(UInt32(dimension))
    writer.write_u64(UInt64(record_count))


def _write_live_body(mut writer: BinaryWriter, entry: MemTableEntry) raises:
    for value in entry.values:
        writer.write_f32(value)
    var payload = encode_payload(entry.fields)
    writer.write_u32(UInt32(len(payload)))
    writer.write_bytes(payload)


def _finish_segment(var writer: BinaryWriter) -> List[UInt8]:
    var body = writer.take_bytes()
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def _read_u32_at(bytes: List[UInt8], offset: Int) -> Int:
    return Int(
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )
