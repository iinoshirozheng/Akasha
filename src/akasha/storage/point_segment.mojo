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
from akasha.storage.mapped_file import MappedFile


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


def encode_point_segment_header(
    kind: Int,
    min_sequence: UInt64,
    last_sequence: UInt64,
    count: Int,
    catalog: FieldCatalog,
) raises -> List[UInt8]:
    """Shared v5 header for owned and streamed complete-state segments."""
    if count < 0:
        raise Error("point segment record count must be nonnegative")
    var catalog_crc = field_catalog_checksum(catalog)
    _validate_interval(kind, min_sequence, last_sequence, catalog)
    var writer = BinaryWriter()
    writer.write_u32(_MAGIC)
    writer.write_u16(5)
    writer.write_u16(UInt16(kind))
    writer.write_u64(catalog.schema_revision)
    writer.write_u32(catalog_crc)
    writer.write_u32(0)
    writer.write_u64(UInt64(count))
    writer.write_u64(min_sequence)
    writer.write_u64(last_sequence)
    return writer.take_bytes()


def encode_point_segment(
    kind: Int,
    min_sequence: UInt64,
    last_sequence: UInt64,
    points: List[PointState],
    catalog: FieldCatalog,
    *,
    payload_version: Int = 2,
) raises -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_bytes(
        encode_point_segment_header(
            kind, min_sequence, last_sequence, len(points), catalog
        )
    )
    var previous_id = 0
    for index in range(len(points)):
        ref point = points[index]
        if index > 0 and point.id <= previous_id:
            raise Error("point segment IDs must strictly increase")
        previous_id = point.id
        _validate_point(point, kind, min_sequence, last_sequence)
        writer.write_bytes(encode_point_record(point, catalog, payload_version=payload_version))
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
    var header = _decode_point_segment_header(
        reader.read_span(48), len(bytes) - 52, catalog, catalog_crc
    )
    var version = header[0]
    var kind = header[1]
    var count = header[2]
    var minimum = header[3]
    var maximum = header[4]
    var points = List[PointState](capacity=count)
    var previous_id = 0
    for index in range(count):
        var start = reader.position()
        var size = Int(reader.read_u32())
        _validate_record_length(size, reader.remaining() + 4)
        _ = reader.read_span(size - 4)
        var point = _decode_segment_point(
            bytes[start : start + size],
            catalog,
            version,
            kind,
            minimum,
            maximum,
            index,
            previous_id,
        )
        previous_id = point.id
        points.append(point^)
    if reader.remaining() != 0:
        raise Error("unexpected point segment trailing bytes")
    return PointSegment(kind, minimum, maximum, checksum, points^)


def _decode_point_segment_header(
    bytes: Span[UInt8, _],
    record_bytes: Int,
    catalog: FieldCatalog,
    catalog_crc: UInt32,
) raises -> Tuple[Int, Int, Int, UInt64, UInt64]:
    var reader = BorrowedBinaryReader(bytes)
    var magic = reader.read_u32()
    var version = reader.read_u16()
    if magic != _MAGIC or (version != 4 and version != 5):
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
    if count > UInt64(record_bytes // 40):
        raise Error("point segment count exceeds available bytes")
    return (Int(version), kind, Int(count), minimum, maximum)


def _validate_record_length(size: Int, remaining: Int) raises:
    if size < 40 or size > MAX_POINT_RECORD_BYTES:
        raise Error("invalid point segment record length")
    if size > remaining:
        raise Error("truncated binary value")


def _decode_segment_point(
    bytes: Span[UInt8, _],
    catalog: FieldCatalog,
    version: Int,
    kind: Int,
    minimum: UInt64,
    maximum: UInt64,
    index: Int,
    previous_id: Int,
) raises -> PointState:
    var point = decode_point_record(bytes, catalog)
    if version == 4:
        for field_index in range(point.field_count()):
            ref value = point.field_at(field_index).value()
            if value.kind() == 1:
                for element in value.sparse_values():
                    if element.weight == 0:
                        raise Error("v4 sparse weights must be non-zero")
    if index > 0 and point.id <= previous_id:
        raise Error("point segment IDs must strictly increase")
    _validate_point(point, kind, minimum, maximum)
    return point^


struct PointSegmentCursor[origin: ImmOrigin](Movable):
    """One pinned immutable v4/v5 mapping and at most one decoded record.

    Each read validates the same bounded record as the owned decoder. Rewind
    reuses the verified inode, never reopening a possibly replaced pathname.
    Callers must keep committed inputs immutable for the cursor's lifetime.
    """

    var kind: Int
    var min_sequence: UInt64
    var last_sequence: UInt64
    var checksum: UInt32
    var _mapping: MappedFile
    var _catalog: Pointer[FieldCatalog, Self.origin]
    var _version: Int
    var _count: Int
    var _index: Int
    var _offset: Int
    var _previous_id: Int

    def __init__(
        out self, path: String, ref[Self.origin] catalog: FieldCatalog
    ) raises:
        var mapping = MappedFile.open_readonly(path)
        var encoded_size = mapping.byte_length()
        if encoded_size < 52:
            raise Error("truncated point segment")
        var checksum = mapping.load_scalars[DType.uint32, 1](encoded_size - 4)
        if mapping.checksum(4, UInt64(encoded_size - 8)) != checksum:
            raise Error("point segment checksum mismatch")
        var header_bytes = mapping.copy_scalars[DType.uint8](0, 48)
        var header = _decode_point_segment_header(
            Span(header_bytes),
            encoded_size - 52,
            catalog,
            field_catalog_checksum(catalog),
        )
        mapping.release_descriptor()
        self.kind = header[1]
        self.min_sequence = header[3]
        self.last_sequence = header[4]
        self.checksum = checksum
        self._mapping = mapping^
        self._catalog = Pointer(to=catalog)
        self._version = header[0]
        self._count = header[2]
        self._index = 0
        self._offset = 48
        self._previous_id = 0

    def rewind(mut self):
        self._index = 0
        self._offset = 48
        self._previous_id = 0

    def read_next(mut self) raises -> Optional[PointState]:
        var end = self._mapping.byte_length() - 4
        if self._index == self._count:
            if self._offset != end:
                raise Error("unexpected point segment trailing bytes")
            return None
        if end - self._offset < 4:
            raise Error("truncated binary value")
        var size = Int(
            self._mapping.load_scalars[DType.uint32, 1](self._offset)
        )
        _validate_record_length(size, end - self._offset)
        var bytes = self._mapping.copy_scalars[DType.uint8](self._offset, size)
        var point = _decode_segment_point(
            Span(bytes),
            self._catalog[],
            self._version,
            self.kind,
            self.min_sequence,
            self.last_sequence,
            self._index,
            self._previous_id,
        )
        if self._index + 1 == self._count and self._offset + size != end:
            raise Error("unexpected point segment trailing bytes")
        self._previous_id = point.id
        self._offset += size
        self._index += 1
        return Optional(point^)


def read_point_segment(
    path: String, catalog: FieldCatalog
) raises -> PointSegment:
    """Collect independently owned records from the shared validated cursor."""
    var cursor = PointSegmentCursor(path, catalog)
    var points = List[PointState](capacity=cursor._count)
    while True:
        var point = cursor.read_next()
        if not point:
            break
        points.append(point.take())
    return PointSegment(
        cursor.kind,
        cursor.min_sequence,
        cursor.last_sequence,
        cursor.checksum,
        points^,
    )
