from akasha.document.point_codec import (
    decode_point_record,
    encode_point_record,
    MAX_POINT_RECORD_BYTES,
)
from akasha.document.point_state import PointState
from akasha.document.vector_schema import FieldCatalog
from akasha.storage.checksum import (
    BinaryWriter,
    BorrowedBinaryReader,
    crc32_range,
    crc32_update,
    CRC32_INITIAL,
)
from akasha.storage.field_catalog import field_catalog_checksum


comptime _MAGIC = UInt32(0x47534B41)


@fieldwise_init
struct PointSegment(Movable):
    var kind: Int
    var min_sequence: UInt64
    var last_sequence: UInt64
    var checksum: UInt32
    var points: List[PointState]


def _validate_interval(
    kind: Int, minimum: UInt64, maximum: UInt64, catalog: FieldCatalog
) raises:
    if (kind != 1 and kind != 2) or minimum > maximum:
        raise Error("invalid point segment kind or sequence interval")
    if (kind == 1 and minimum != 0) or (kind == 2 and minimum == 0):
        raise Error("invalid point segment minimum sequence")
    if maximum < catalog.legacy_cutover_sequence:
        raise Error("point segment checkpoint precedes migration cutover")


def _validate_point(
    point: PointState, kind: Int, minimum: UInt64, maximum: UInt64
) raises:
    if point.sequence < minimum or point.sequence > maximum:
        raise Error("point sequence lies outside segment interval")
    if kind == 1 and point.tombstone:
        raise Error("base segment cannot contain tombstones")


def encode_point_segment(
    kind: Int,
    min_sequence: UInt64,
    last_sequence: UInt64,
    points: List[PointState],
    catalog: FieldCatalog,
) raises -> List[UInt8]:
    var catalog_crc = field_catalog_checksum(catalog)
    _validate_interval(kind, min_sequence, last_sequence, catalog)
    var writer = BinaryWriter()
    writer.write_u32(_MAGIC)
    writer.write_u16(4)
    writer.write_u16(UInt16(kind))
    writer.write_u64(catalog.schema_revision)
    writer.write_u32(catalog_crc)
    writer.write_u32(0)
    writer.write_u64(UInt64(len(points)))
    writer.write_u64(min_sequence)
    writer.write_u64(last_sequence)
    var previous_id = 0
    for index in range(len(points)):
        ref point = points[index]
        if index > 0 and point.id <= previous_id:
            raise Error("point segment IDs must strictly increase")
        previous_id = point.id
        _validate_point(point, kind, min_sequence, last_sequence)
        writer.write_bytes(encode_point_record(point, catalog))
    var bytes = writer.take_bytes()
    var checksum = crc32_range(bytes, 4, len(bytes))
    for shift in range(0, 32, 8):
        bytes.append(UInt8(checksum >> UInt32(shift)))
    return bytes^


def decode_point_segment(
    bytes: List[UInt8], catalog: FieldCatalog
) raises -> PointSegment:
    return decode_point_segment(Span(bytes), catalog)


def decode_point_segment(
    bytes: Span[UInt8, _], catalog: FieldCatalog
) raises -> PointSegment:
    var catalog_crc = field_catalog_checksum(catalog)
    if len(bytes) < 52:
        raise Error("truncated point segment")
    var checksum_reader = BorrowedBinaryReader(bytes[len(bytes) - 4 :])
    var checksum = checksum_reader.read_u32()
    if ~crc32_update(CRC32_INITIAL, bytes[4 : len(bytes) - 4]) != checksum:
        raise Error("point segment checksum mismatch")
    var reader = BorrowedBinaryReader(bytes[: len(bytes) - 4])
    if reader.read_u32() != _MAGIC or reader.read_u16() != 4:
        raise Error("invalid point segment magic or version")
    var kind = Int(reader.read_u16())
    if (
        reader.read_u64() != catalog.schema_revision
        or reader.read_u32() != catalog_crc
        or reader.read_u32() != 0
    ):
        raise Error("point segment catalog identity or reserved field mismatch")
    var count = reader.read_u64()
    var minimum = reader.read_u64()
    var maximum = reader.read_u64()
    _validate_interval(kind, minimum, maximum, catalog)
    if count > UInt64(reader.remaining() // 40):
        raise Error("point segment count exceeds available bytes")
    var points = List[PointState](capacity=Int(count))
    var previous_id = 0
    for index in range(Int(count)):
        var start = reader.position()
        var size = Int(reader.read_u32())
        if size < 40 or size > MAX_POINT_RECORD_BYTES:
            raise Error("invalid point segment record length")
        _ = reader.read_span(size - 4)
        var point = decode_point_record(bytes[start : start + size], catalog)
        if index > 0 and point.id <= previous_id:
            raise Error("point segment IDs must strictly increase")
        previous_id = point.id
        _validate_point(point, kind, minimum, maximum)
        points.append(point^)
    if reader.remaining() != 0:
        raise Error("unexpected point segment trailing bytes")
    return PointSegment(kind, minimum, maximum, checksum, points^)
