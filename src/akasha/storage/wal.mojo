from akasha.document.codec import (
    decode_payload,
    encode_payload,
    MAX_PAYLOAD_BYTES,
)
from akasha.document.record import DocumentField
from akasha.storage.checksum import (
    BinaryReader,
    BinaryWriter,
    crc32_range,
)
from akasha.storage.filesystem import (
    append_file_sync,
    atomic_replace,
    path_exists,
    read_file_bytes,
    sync_directory,
    write_file_sync,
)


comptime _MAGIC_0 = UInt8(0x41)  # A
comptime _MAGIC_1 = UInt8(0x4B)  # K
comptime _MAGIC_2 = UInt8(0x57)  # W
comptime _MAGIC_3 = UInt8(0x4C)  # L
comptime _VERSION_V1 = UInt16(1)
comptime _VERSION_V2 = UInt16(2)
comptime _VERSION_V3 = UInt16(3)
comptime _UPSERT = UInt8(1)
comptime _DELETE = UInt8(2)
comptime _BATCH = UInt8(3)
comptime _HEADER_SIZE = 32
comptime _MIN_RECORD_SIZE = 36
comptime _MUTATION_HEADER_SIZE = 16
comptime _MAX_BATCH_RECORDS = 65_536
comptime _MAX_BATCH_BYTES = 256 * 1024 * 1024


struct WalRecord(Movable):
    """One decoded, checksummed mutation."""

    var sequence: UInt64
    var id: Int
    var is_delete: Bool
    var values: List[Float32]
    var fields: List[DocumentField]

    def __init__(
        out self,
        sequence: UInt64,
        id: Int,
        is_delete: Bool,
        var values: List[Float32],
    ):
        self.sequence = sequence
        self.id = id
        self.is_delete = is_delete
        self.values = values^
        self.fields = List[DocumentField]()

    @staticmethod
    def with_fields(
        sequence: UInt64,
        id: Int,
        is_delete: Bool,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) -> WalRecord:
        var record = WalRecord(sequence, id, is_delete, values^)
        record.fields = fields^
        return record^

    @staticmethod
    def upsert(
        sequence: UInt64, id: Int, var values: List[Float32]
    ) -> WalRecord:
        return WalRecord(sequence, id, False, values^)

    @staticmethod
    def delete(sequence: UInt64, id: Int) -> WalRecord:
        return WalRecord(sequence, id, True, List[Float32]())

    @staticmethod
    def document_upsert(
        sequence: UInt64,
        id: Int,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) -> WalRecord:
        return WalRecord.with_fields(sequence, id, False, values^, fields^)


struct WalReplayState(Movable):
    """One read-only WAL decode plus optional accepted-tail repair bytes."""

    var records: List[WalRecord]
    var valid_prefix: List[UInt8]
    var valid_length: Int
    var source_length: Int

    def __init__(
        out self,
        var records: List[WalRecord],
        var valid_prefix: List[UInt8],
        valid_length: Int,
        source_length: Int,
    ):
        self.records = records^
        self.valid_prefix = valid_prefix^
        self.valid_length = valid_length
        self.source_length = source_length

    def needs_repair(self) -> Bool:
        return self.valid_length < self.source_length

    def take_records(deinit self) -> List[WalRecord]:
        return self.records^


def encode_upsert(
    sequence: UInt64,
    id: Int,
    dimension: Int,
    values: List[Float32],
) raises -> List[UInt8]:
    if dimension <= 0 or len(values) != dimension:
        raise Error("WAL upsert dimension mismatch")
    var fields = List[DocumentField]()
    return _encode_record(sequence, id, dimension, _UPSERT, values, fields)


def encode_document_upsert(
    sequence: UInt64,
    id: Int,
    dimension: Int,
    values: List[Float32],
    fields: List[DocumentField],
) raises -> List[UInt8]:
    if dimension <= 0 or len(values) != dimension:
        raise Error("WAL upsert dimension mismatch")
    return _encode_record(sequence, id, dimension, _UPSERT, values, fields)


def encode_delete(
    sequence: UInt64, id: Int, dimension: Int
) raises -> List[UInt8]:
    if dimension <= 0:
        raise Error("WAL dimension must be positive")
    var empty = List[Float32]()
    var fields = List[DocumentField]()
    return _encode_record(sequence, id, dimension, _DELETE, empty, fields)


def append_wal(path: String, dimension: Int, record: WalRecord) raises:
    var bytes: List[UInt8]
    if record.is_delete:
        bytes = encode_delete(record.sequence, record.id, dimension)
    else:
        bytes = encode_document_upsert(
            record.sequence,
            record.id,
            dimension,
            record.values,
            record.fields,
        )
    append_file_sync(path, bytes)


def append_wal_batch(
    path: String, dimension: Int, records: List[WalRecord]
) raises:
    """Append and fsync one atomic v3 mutation envelope."""
    var bytes = encode_batch(dimension, records)
    append_file_sync(path, bytes)


def encode_batch(
    dimension: Int, records: List[WalRecord]
) raises -> List[UInt8]:
    if dimension <= 0:
        raise Error("WAL dimension must be positive")
    if len(records) == 0:
        raise Error("WAL batch cannot be empty")
    if len(records) > _MAX_BATCH_RECORDS:
        raise Error("WAL batch record count is too large")
    var first_sequence = records[0].sequence
    if first_sequence == 0:
        raise Error("WAL sequence must be positive")
    if first_sequence > UInt64.MAX - UInt64(len(records) - 1):
        raise Error("WAL batch sequence range overflows")

    var body = BinaryWriter()
    for index in range(len(records)):
        if records[index].sequence != first_sequence + UInt64(index):
            raise Error("WAL batch sequences must be contiguous")
        body.write_u8(_DELETE if records[index].is_delete else _UPSERT)
        body.write_u8(0)
        body.write_u16(0)
        body.write_i64(Int64(records[index].id))
        if records[index].is_delete:
            if (
                len(records[index].values) != 0
                or len(records[index].fields) != 0
            ):
                raise Error("WAL delete cannot contain values or fields")
            body.write_u32(0)
            continue
        if len(records[index].values) != dimension:
            raise Error("WAL upsert dimension mismatch")
        var payload = encode_payload(records[index].fields)
        var mutation_size = dimension * 4 + 4 + len(payload)
        body.write_u32(UInt32(mutation_size))
        for value in records[index].values:
            body.write_f32(value)
        body.write_u32(UInt32(len(payload)))
        body.write_bytes(payload)

    var body_bytes = body.take_bytes()
    var record_size = _HEADER_SIZE + len(body_bytes) + 4
    if record_size > _MAX_BATCH_BYTES:
        raise Error("WAL batch encoded size is too large")
    var writer = BinaryWriter()
    writer.write_u8(_MAGIC_0)
    writer.write_u8(_MAGIC_1)
    writer.write_u8(_MAGIC_2)
    writer.write_u8(_MAGIC_3)
    writer.write_u16(_VERSION_V3)
    writer.write_u8(_BATCH)
    writer.write_u8(0)
    writer.write_u32(UInt32(record_size))
    writer.write_u64(first_sequence)
    writer.write_u32(UInt32(len(records)))
    writer.write_u32(UInt32(dimension))
    writer.write_u32(0)
    writer.write_bytes(body_bytes)
    var encoded = writer.take_bytes()
    var checksum = crc32_range(encoded, 4, len(encoded))
    var complete = BinaryWriter()
    complete.write_bytes(encoded)
    complete.write_u32(checksum)
    return complete.take_bytes()


def rotate_wal(directory: String) raises:
    """Atomically replace the collection WAL with a durable empty file."""
    var temporary_path = directory + "/wal.bin.tmp"
    var final_path = directory + "/wal.bin"
    var empty = List[UInt8]()
    write_file_sync(temporary_path, empty)
    atomic_replace(temporary_path, final_path)
    sync_directory(directory)


def replay_wal(path: String, dimension: Int) raises -> List[WalRecord]:
    var replay = preflight_wal(path, dimension)
    return replay^.take_records()


def recover_wal(path: String, dimension: Int) raises -> List[WalRecord]:
    """Replay a WAL and durably remove an accepted torn EOF tail."""
    var replay = preflight_wal(path, dimension)
    repair_wal_tail(path, replay)
    return replay^.take_records()


def preflight_wal(path: String, dimension: Int) raises -> WalReplayState:
    """Decode once without modifying a missing file or accepted torn tail."""
    if not path_exists(path):
        return WalReplayState(
            List[WalRecord](), List[UInt8](), 0, 0
        )
    var bytes = read_file_bytes(path)
    var decode_copy = _copy_range(bytes, 0, len(bytes))
    var records = decode_wal_bytes(decode_copy^, dimension)
    var valid_length = _valid_prefix_length(bytes)
    var valid_prefix = List[UInt8]()
    if valid_length < len(bytes):
        valid_prefix = _copy_range(bytes, 0, valid_length)
    return WalReplayState(
        records^, valid_prefix^, valid_length, len(bytes)
    )


def repair_wal_tail(path: String, replay: WalReplayState) raises:
    """Apply only the tail repair established by ``preflight_wal``."""
    if replay.needs_repair():
        write_file_sync(path, replay.valid_prefix)


def decode_wal_bytes(
    var bytes: List[UInt8], dimension: Int
) raises -> List[WalRecord]:
    if dimension <= 0:
        raise Error("WAL dimension must be positive")

    var records = List[WalRecord]()
    var offset = 0
    var previous_sequence = UInt64(0)
    var maximum_record_size = 40 + dimension * 4 + MAX_PAYLOAD_BYTES

    while offset < len(bytes):
        var remaining = len(bytes) - offset
        if remaining < _HEADER_SIZE:
            break
        if not _has_magic(bytes, offset):
            raise Error("invalid WAL record magic")

        var version = UInt16(bytes[offset + 4]) | (
            UInt16(bytes[offset + 5]) << UInt16(8)
        )
        var maximum_size = maximum_record_size
        if version == _VERSION_V3:
            maximum_size = _MAX_BATCH_BYTES
        var record_size = _read_u32_at(bytes, offset + 8)
        if record_size < _MIN_RECORD_SIZE or record_size > maximum_size:
            raise Error("invalid WAL record length")
        if remaining < record_size:
            break

        var encoded = _copy_range(bytes, offset, offset + record_size)
        if version == _VERSION_V3:
            if bytes[offset + 6] != _BATCH:
                raise Error("invalid WAL v3 operation")
            previous_sequence = _decode_batch(
                encoded^, dimension, previous_sequence, records
            )
            offset += record_size
            continue
        var record = _decode_record(encoded^, dimension)
        if record.sequence <= previous_sequence:
            raise Error("WAL sequence must increase")
        previous_sequence = record.sequence
        records.append(record^)
        offset += record_size

    return records^


def _decode_batch(
    var bytes: List[UInt8],
    expected_dimension: Int,
    previous_sequence: UInt64,
    mut records: List[WalRecord],
) raises -> UInt64:
    var encoded_size = len(bytes)
    var stored_checksum = _read_u32_at(bytes, encoded_size - 4)
    if crc32_range(bytes, 4, encoded_size - 4) != UInt32(stored_checksum):
        raise Error("WAL checksum mismatch")

    var reader = BinaryReader(bytes^)
    if (
        reader.read_u8() != _MAGIC_0
        or reader.read_u8() != _MAGIC_1
        or reader.read_u8() != _MAGIC_2
        or reader.read_u8() != _MAGIC_3
    ):
        raise Error("invalid WAL record magic")
    if reader.read_u16() != _VERSION_V3 or reader.read_u8() != _BATCH:
        raise Error("invalid WAL v3 batch header")
    if reader.read_u8() != 0:
        raise Error("unsupported WAL flags")
    if Int(reader.read_u32()) != encoded_size:
        raise Error("WAL record length mismatch")
    var first_sequence = reader.read_u64()
    var count_u32 = reader.read_u32()
    var count = Int(count_u32)
    if count == 0 or count > _MAX_BATCH_RECORDS:
        raise Error("invalid WAL batch record count")
    var dimension = Int(reader.read_u32())
    if dimension != expected_dimension:
        raise Error("WAL dimension mismatch")
    if reader.read_u32() != 0:
        raise Error("unsupported WAL batch reserved field")
    if first_sequence == 0 or first_sequence <= previous_sequence:
        raise Error("WAL sequence must increase")
    if first_sequence > UInt64.MAX - UInt64(count - 1):
        raise Error("WAL batch sequence range overflows")

    for index in range(count):
        var operation = reader.read_u8()
        if operation != _UPSERT and operation != _DELETE:
            raise Error("invalid WAL batch mutation operation")
        if reader.read_u8() != 0 or reader.read_u16() != 0:
            raise Error("unsupported WAL batch mutation flags")
        var id = Int(reader.read_i64())
        var mutation_size = Int(reader.read_u32())
        var sequence = first_sequence + UInt64(index)
        if operation == _DELETE:
            if mutation_size != 0:
                raise Error("WAL batch delete cannot contain a body")
            records.append(WalRecord.delete(sequence, id))
            continue

        if mutation_size < dimension * 4 + 4:
            raise Error("WAL batch upsert body is truncated")
        var values = List[Float32](capacity=dimension)
        for _ in range(dimension):
            values.append(reader.read_f32())
        var payload_length = Int(reader.read_u32())
        if mutation_size != dimension * 4 + 4 + payload_length:
            raise Error("WAL batch mutation length mismatch")
        var payload = reader.read_bytes(payload_length)
        var fields = decode_payload(payload^)
        records.append(
            WalRecord.document_upsert(sequence, id, values^, fields^)
        )

    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected WAL batch payload")
    return first_sequence + UInt64(count - 1)


def _encode_record(
    sequence: UInt64,
    id: Int,
    dimension: Int,
    operation: UInt8,
    values: List[Float32],
    fields: List[DocumentField],
) raises -> List[UInt8]:
    if sequence == 0:
        raise Error("WAL sequence must be positive")
    var payload = List[UInt8]()
    if operation == _UPSERT:
        payload = encode_payload(fields)
    elif len(fields) != 0:
        raise Error("WAL delete cannot contain fields")
    var vector_size = 0 if operation == _DELETE else dimension * 4
    var record_size = 40 + vector_size + len(payload)

    var writer = BinaryWriter()
    writer.write_u8(_MAGIC_0)
    writer.write_u8(_MAGIC_1)
    writer.write_u8(_MAGIC_2)
    writer.write_u8(_MAGIC_3)
    writer.write_u16(_VERSION_V2)
    writer.write_u8(operation)
    writer.write_u8(0)
    writer.write_u32(UInt32(record_size))
    writer.write_u64(sequence)
    writer.write_i64(Int64(id))
    writer.write_u32(UInt32(dimension))
    if operation == _UPSERT:
        for value in values:
            writer.write_f32(value)
    writer.write_u32(UInt32(len(payload)))
    writer.write_bytes(payload)

    var body = writer.take_bytes()
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def _decode_record(
    var bytes: List[UInt8], expected_dimension: Int
) raises -> WalRecord:
    var encoded_size = len(bytes)
    var stored_checksum = _read_u32_at(bytes, len(bytes) - 4)
    if crc32_range(bytes, 4, len(bytes) - 4) != UInt32(stored_checksum):
        raise Error("WAL checksum mismatch")

    var reader = BinaryReader(bytes^)
    if (
        reader.read_u8() != _MAGIC_0
        or reader.read_u8() != _MAGIC_1
        or reader.read_u8() != _MAGIC_2
        or reader.read_u8() != _MAGIC_3
    ):
        raise Error("invalid WAL record magic")
    var version = reader.read_u16()
    if version != _VERSION_V1 and version != _VERSION_V2:
        raise Error("unsupported WAL version")
    var operation = reader.read_u8()
    if operation != _UPSERT and operation != _DELETE:
        raise Error("invalid WAL operation")
    if reader.read_u8() != 0:
        raise Error("unsupported WAL flags")
    var record_size = Int(reader.read_u32())
    if record_size != encoded_size:
        raise Error("WAL record length mismatch")
    var sequence = reader.read_u64()
    if sequence == 0:
        raise Error("WAL sequence must be positive")
    var id = Int(reader.read_i64())
    var dimension = Int(reader.read_u32())
    if dimension != expected_dimension:
        raise Error("WAL dimension mismatch")

    var values = List[Float32](capacity=dimension)
    if operation == _UPSERT:
        for _ in range(dimension):
            values.append(reader.read_f32())
    var fields = List[DocumentField]()
    if version == _VERSION_V2:
        var payload_length = Int(reader.read_u32())
        if operation == _DELETE and payload_length != 0:
            raise Error("WAL delete cannot contain payload")
        var payload = reader.read_bytes(payload_length)
        if operation == _UPSERT:
            fields = decode_payload(payload^)
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected WAL payload")
    return WalRecord.with_fields(
        sequence, id, operation == _DELETE, values^, fields^
    )


def _has_magic(bytes: List[UInt8], offset: Int) -> Bool:
    return (
        bytes[offset] == _MAGIC_0
        and bytes[offset + 1] == _MAGIC_1
        and bytes[offset + 2] == _MAGIC_2
        and bytes[offset + 3] == _MAGIC_3
    )


def _read_u32_at(bytes: List[UInt8], offset: Int) -> Int:
    return Int(
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )


def _copy_range(bytes: List[UInt8], start: Int, end: Int) -> List[UInt8]:
    var result = List[UInt8](capacity=end - start)
    for index in range(start, end):
        result.append(bytes[index])
    return result^


def _valid_prefix_length(bytes: List[UInt8]) -> Int:
    var offset = 0
    while offset < len(bytes):
        var remaining = len(bytes) - offset
        if remaining < _HEADER_SIZE:
            break
        var record_size = _read_u32_at(bytes, offset + 8)
        if remaining < record_size:
            break
        offset += record_size
    return offset
