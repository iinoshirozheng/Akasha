from akasha.document.codec import (
    decode_payload,
    encode_payload,
    MAX_PAYLOAD_BYTES,
)
from akasha.document.point_codec import (
    decode_vector_value,
    encode_vector_value,
    vector_value_size,
)
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.record import DocumentField
from akasha.document.vector_schema import FieldCatalog, MAX_VECTOR_FIELDS
from akasha.storage.checksum import (
    BinaryWriter,
    BorrowedBinaryReader,
    crc32_range,
    crc32_update,
    CRC32_INITIAL,
)
from akasha.storage.field_catalog import field_catalog_checksum
from akasha.storage.filesystem import path_exists
from akasha.storage.wal import WalRecord, _decode_envelope, _envelope_size
from akasha.storage.wal_buffer import WalReadBuffer
from std.memory import ArcPointer
from std.utils import Variant


comptime MAX_POINT_BATCH_MUTATIONS = 65_536
comptime MAX_POINT_BATCH_BYTES = 256 * 1024 * 1024
comptime _MAGIC = UInt32(0x4C574B41)


@fieldwise_init
struct PointWalBatch(Movable):
    var first_sequence: UInt64
    var mutations: List[PointMutation]

    def last_sequence(self) raises -> UInt64:
        if (
            len(self.mutations) == 0
            or self.first_sequence == 0
            or self.first_sequence
            > UInt64.MAX - UInt64(len(self.mutations) - 1)
        ):
            raise Error("invalid field-aware WAL batch sequence range")
        return self.first_sequence + UInt64(len(self.mutations) - 1)


comptime _RecoveredData = Variant[List[WalRecord], PointWalBatch]


@fieldwise_init
struct RecoveredWalEnvelope(Movable):
    """Owned accepted mutations, retaining the legacy decoder's contract."""

    var format_version: Int
    var _data: _RecoveredData

    def is_legacy(self) -> Bool:
        return self._data.isa[List[WalRecord]]()

    def legacy_records(
        self,
    ) raises -> ref[origin_of(self._data[List[WalRecord]], self)] List[
        WalRecord
    ]:
        if not self.is_legacy():
            raise Error("field-aware envelope has no legacy records")
        return self._data[List[WalRecord]]

    def point_batch(
        self,
    ) raises -> ref[origin_of(self._data[PointWalBatch], self)] PointWalBatch:
        if self.is_legacy():
            raise Error("legacy envelope has no field-aware batch")
        return self._data[PointWalBatch]

    def take_legacy_records(deinit self) raises -> List[WalRecord]:
        if not self.is_legacy():
            raise Error("field-aware envelope has no legacy records")
        return self._data^.unwrap[List[WalRecord]]()

    def take_point_batch(deinit self) raises -> PointWalBatch:
        if self.is_legacy():
            raise Error("legacy envelope has no field-aware batch")
        return self._data^.unwrap[PointWalBatch]()


struct FieldWalReader(Movable):
    """Bounded mixed v1-v4 envelope preflight; never publishes or repairs.

    Legacy records must end at/before catalog cutover. New batches must start
    after it. The caller completes legacy dense/sparse replay before applying
    new patches and holds collection exclusion for this reader's lifetime.
    """

    var _input: WalReadBuffer
    var _catalog: ArcPointer[FieldCatalog]
    var _catalog_crc: UInt32
    var _previous_sequence: UInt64
    var _done: Bool
    var _failed: Bool
    var valid_length: Int
    var source_length: Int

    def __init__(
        out self, path: String, var catalog: ArcPointer[FieldCatalog]
    ) raises:
        self._catalog_crc = field_catalog_checksum(catalog[])
        self._catalog = catalog^
        self._input = WalReadBuffer(path, path_exists(path))
        self._previous_sequence = 0
        self._done = False
        self._failed = False
        self.valid_length = 0
        self.source_length = self._input.source_length

    def buffer_capacity(self) -> Int:
        return self._input.capacity()

    def read_next(mut self) raises -> Optional[RecoveredWalEnvelope]:
        if self._failed:
            raise Error("cannot resume a failed field-aware WAL reader")
        var remaining = self.source_length - self.valid_length
        if self._done or remaining < 32:
            self._done = True
            return Optional[RecoveredWalEnvelope]()
        self._failed = True
        self._input.ensure_available(32, self.valid_length)
        var version = Int(self._input.bytes()[4]) | (
            Int(self._input.bytes()[5]) << 8
        )
        var dimension = self._catalog[].field_at(0).dimension
        var size: Int
        if version == 4:
            size = point_batch_size(self._input.bytes())
        else:
            size = _envelope_size(self._input.bytes(), dimension)
        if remaining < size:
            self._done = True
            self._failed = False
            return Optional[RecoveredWalEnvelope]()
        self._input.ensure_available(size, self.valid_length)
        var envelope: RecoveredWalEnvelope
        if version == 4:
            var batch = _decode_point_batch(
                self._input.bytes()[:size],
                self._catalog[],
                self._catalog_crc,
                self._previous_sequence,
            )
            self._previous_sequence = batch.last_sequence()
            envelope = RecoveredWalEnvelope(4, _RecoveredData(batch^))
        else:
            var records = _decode_envelope(
                self._input.bytes()[:size], dimension, self._previous_sequence
            )
            var last = records[len(records) - 1].sequence
            if last > self._catalog[].legacy_cutover_sequence:
                raise Error("legacy WAL envelope crosses catalog cutover")
            self._previous_sequence = last
            envelope = RecoveredWalEnvelope(version, _RecoveredData(records^))
        self._input.consume(size)
        self.valid_length += size
        self._failed = False
        return Optional(envelope^)


def _validate_range(
    first: UInt64, count: Int, catalog: FieldCatalog, previous: UInt64
) raises:
    if count < 1 or count > MAX_POINT_BATCH_MUTATIONS:
        raise Error("invalid field-aware WAL mutation count")
    if (
        first == 0
        or first <= catalog.legacy_cutover_sequence
        or first <= previous
    ):
        raise Error(
            "field-aware WAL sequence must follow cutover and previous envelope"
        )
    if first > UInt64.MAX - UInt64(count - 1):
        raise Error("field-aware WAL sequence range overflows")


def _encode_mutation(
    mutation: PointMutation, catalog: FieldCatalog
) raises -> List[UInt8]:
    mutation.validate(catalog)
    var payload = List[UInt8]()
    var length = 0
    if mutation.replaces_payload():
        payload = encode_payload(mutation.payload())
        length = 4 + len(payload)
    for index in range(mutation.field_count()):
        ref field = mutation.field_at(index)
        var size = 0
        if not field.is_remove():
            size = vector_value_size(
                field.value(), catalog.field_at(catalog.ordinal_for(field.id))
            )
        if size > MAX_POINT_BATCH_BYTES - 64 - length - 12:
            raise Error("field-aware WAL mutation exceeds envelope limit")
        length += 12 + size
    var writer = BinaryWriter()
    writer.write_i64(Int64(mutation.id))
    writer.write_u8(mutation.kind)
    writer.write_u8(UInt8(1) if mutation.replaces_payload() else UInt8(0))
    writer.write_u16(0)
    writer.write_u32(UInt32(mutation.field_count()))
    writer.write_u32(UInt32(length))
    if mutation.replaces_payload():
        writer.write_u32(UInt32(len(payload)))
        writer.write_bytes(payload)
    for index in range(mutation.field_count()):
        ref field = mutation.field_at(index)
        var body = List[UInt8]()
        if not field.is_remove():
            body = encode_vector_value(
                field.value(), catalog.field_at(catalog.ordinal_for(field.id))
            )
        writer.write_u32(UInt32(field.id))
        writer.write_u8(UInt8(2) if field.is_remove() else UInt8(1))
        writer.write_u8(0)
        writer.write_u16(0)
        writer.write_u32(UInt32(len(body)))
        writer.write_bytes(body)
    return writer.take_bytes()


def encode_point_batch(
    first_sequence: UInt64,
    mutations: List[PointMutation],
    catalog: FieldCatalog,
) raises -> List[UInt8]:
    var catalog_crc = field_catalog_checksum(catalog)
    _validate_range(first_sequence, len(mutations), catalog, 0)
    var bodies = List[List[UInt8]](capacity=len(mutations))
    var total = 44
    for index in range(len(mutations)):
        var body = _encode_mutation(mutations[index], catalog)
        if len(body) > MAX_POINT_BATCH_BYTES - total:
            raise Error("field-aware WAL batch exceeds envelope limit")
        total += len(body)
        bodies.append(body^)
    var writer = BinaryWriter()
    writer.write_u32(_MAGIC)
    writer.write_u16(4)
    writer.write_u8(4)
    writer.write_u8(0)
    writer.write_u32(UInt32(total))
    writer.write_u64(first_sequence)
    writer.write_u32(UInt32(len(mutations)))
    writer.write_u64(catalog.schema_revision)
    writer.write_u32(catalog_crc)
    writer.write_u32(0)
    for index in range(len(bodies)):
        writer.write_bytes(bodies[index])
    var bytes = writer.take_bytes()
    var checksum = crc32_range(bytes, 4, len(bytes))
    for shift in range(0, 32, 8):
        bytes.append(UInt8(checksum >> UInt32(shift)))
    return bytes^


def point_batch_size(bytes: Span[UInt8, _]) raises -> Int:
    """Validate framing from the common 32-byte WAL prefix, without allocation.
    """
    if len(bytes) < 32:
        raise Error("truncated field-aware WAL framing")
    var reader = BorrowedBinaryReader(bytes)
    if reader.read_u32() != _MAGIC:
        raise Error("invalid WAL record magic")
    _ = reader.read_u32()
    var size = Int(reader.read_u32())
    if size < 64 or size > MAX_POINT_BATCH_BYTES:
        raise Error("invalid field-aware WAL envelope length")
    return size


def decode_point_batch(
    bytes: List[UInt8], catalog: FieldCatalog, previous_sequence: UInt64 = 0
) raises -> PointWalBatch:
    return decode_point_batch(Span(bytes), catalog, previous_sequence)


def decode_point_batch(
    bytes: Span[UInt8, _], catalog: FieldCatalog, previous_sequence: UInt64 = 0
) raises -> PointWalBatch:
    return _decode_point_batch(
        bytes, catalog, field_catalog_checksum(catalog), previous_sequence
    )


def _decode_point_batch(
    bytes: Span[UInt8, _],
    catalog: FieldCatalog,
    catalog_crc: UInt32,
    previous_sequence: UInt64,
) raises -> PointWalBatch:
    if point_batch_size(bytes) != len(bytes):
        raise Error("field-aware WAL envelope length mismatch")
    var checksum_reader = BorrowedBinaryReader(bytes[len(bytes) - 4 :])
    if (
        ~crc32_update(CRC32_INITIAL, bytes[4 : len(bytes) - 4])
        != checksum_reader.read_u32()
    ):
        raise Error("field-aware WAL checksum mismatch")
    var reader = BorrowedBinaryReader(bytes[: len(bytes) - 4])
    _ = reader.read_u32()
    if reader.read_u16() != 4 or reader.read_u8() != 4 or reader.read_u8() != 0:
        raise Error("invalid field-aware WAL version, operation or flags")
    _ = reader.read_u32()
    var first = reader.read_u64()
    var count = Int(reader.read_u32())
    if (
        reader.read_u64() != catalog.schema_revision
        or reader.read_u32() != catalog_crc
        or reader.read_u32() != 0
    ):
        raise Error(
            "field-aware WAL catalog identity or reserved field mismatch"
        )
    _validate_range(first, count, catalog, previous_sequence)
    if count > reader.remaining() // 20:
        raise Error("truncated field-aware WAL mutation headers")
    var mutations = List[PointMutation](capacity=count)
    for _ in range(count):
        var id = Int(reader.read_i64())
        var kind = reader.read_u8()
        var payload_action = reader.read_u8()
        if payload_action > 1 or reader.read_u16() != 0:
            raise Error("invalid point mutation payload action or flags")
        var field_count = Int(reader.read_u32())
        if field_count > MAX_VECTOR_FIELDS:
            raise Error("point mutation field count exceeds bounds")
        var body_size = Int(reader.read_u32())
        var body = BorrowedBinaryReader(reader.read_span(body_size))
        var payload = Optional[List[DocumentField]]()
        if payload_action == 1:
            var size = Int(body.read_u32())
            if size > MAX_PAYLOAD_BYTES:
                raise Error("point mutation payload exceeds bounds")
            payload = Optional(decode_payload(body.read_span(size)))
        if field_count > body.remaining() // 12:
            raise Error("truncated point mutation field headers")
        var fields = List[FieldUpdate](capacity=field_count)
        var previous_id = -1
        for _ in range(field_count):
            var field_id = Int(body.read_u32())
            var ordinal = catalog.ordinal_for(field_id)
            if field_id <= previous_id or ordinal < 0:
                raise Error(
                    "point mutation fields must be known, unique and sorted"
                )
            previous_id = field_id
            var action = body.read_u8()
            if body.read_u8() != 0 or body.read_u16() != 0:
                raise Error("unsupported point mutation field flags")
            var size = Int(body.read_u32())
            if action == 1:
                fields.append(
                    FieldUpdate.set(
                        field_id,
                        decode_vector_value(
                            body.read_span(size), catalog.field_at(ordinal)
                        ),
                    )
                )
            elif action == 2 and size == 0:
                fields.append(FieldUpdate.remove(field_id))
            else:
                raise Error("invalid point mutation field action or length")
        if body.remaining() != 0:
            raise Error("unexpected point mutation body bytes")
        var mutation = PointMutation(id, kind, fields^, payload^)
        mutation.validate(catalog)
        mutations.append(mutation^)
    if reader.remaining() != 0:
        raise Error("unexpected field-aware WAL trailing bytes")
    return PointWalBatch(first, mutations^)
