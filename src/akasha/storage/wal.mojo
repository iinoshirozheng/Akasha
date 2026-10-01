from akasha.document.codec import (
    decode_payload,
    encode_payload,
    MAX_PAYLOAD_BYTES,
)
from akasha.document.record import DocumentField
from akasha.storage.checksum import (
    BorrowedBinaryReader,
    BinaryWriter,
    crc32_range,
    crc32_update,
    CRC32_INITIAL,
)
from akasha.storage.filesystem import (
    append_file_sync,
    atomic_replace,
    path_exists,
    sync_file,
    sync_directory,
    write_file_sync,
)
from akasha.storage.wal_buffer import WalReadBuffer
from std.ffi import c_int, c_long, external_call
from std.io.file import FileHandle, O_CLOEXEC, O_WRONLY
from std.os import SEEK_END
from std.sys import size_of
from std.sys._libc_errno import get_errno


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

    def take_values(mut self) -> List[Float32]:
        """Transfer decoded vectors without copying their allocation."""
        var values = self.values^
        self.values = List[Float32]()
        return values^

    def take_fields(mut self) -> List[DocumentField]:
        """Transfer decoded payload fields without copying their allocation."""
        var fields = self.fields^
        self.fields = List[DocumentField]()
        return fields^


struct WalReplayState(Movable):
    """Owned replay results and lengths for deferred accepted-tail repair."""

    var records: List[WalRecord]
    var valid_length: Int
    var source_length: Int

    def __init__(
        out self,
        var records: List[WalRecord],
        valid_length: Int,
        source_length: Int,
    ):
        self.records = records^
        self.valid_length = valid_length
        self.source_length = source_length

    def needs_repair(self) -> Bool:
        return self.valid_length < self.source_length

    def take_records(deinit self) -> List[WalRecord]:
        return self.records^


trait LegacyWalSource(Movable):
    """Owned legacy envelopes for ordinary or migration-prefix recovery."""

    def read_next(mut self) raises -> List[WalRecord]:
        ...

    def accepted_length(self) -> Int:
        ...

    def total_length(self) -> Int:
        ...


struct WalReader(LegacyWalSource):
    """Read and validate one complete WAL envelope at a time.

    The input buffer is bounded by the largest accepted envelope or 64 KiB,
    independent of total WAL length. Returned mutations own their values; no view survives
    the next buffer refill. The caller must hold collection write exclusion
    while consuming the WAL and applying a deferred repair.
    """

    var _input: WalReadBuffer
    var _dimension: Int
    var _previous_sequence: UInt64
    var _done: Bool
    var _failed: Bool
    var valid_length: Int
    var source_length: Int

    def __init__(out self, path: String, dimension: Int) raises:
        var source_exists = path_exists(path)
        if source_exists:
            _validate_dimension(dimension)
        self._input = WalReadBuffer(path, source_exists)
        self._dimension = dimension
        self._previous_sequence = 0
        self._done = not source_exists
        self._failed = False
        self.valid_length = 0
        self.source_length = self._input.source_length

    def read_next(mut self) raises -> List[WalRecord]:
        if self._failed:
            raise Error("cannot resume a failed WAL reader")
        var remaining = self.source_length - self.valid_length
        if self._done or remaining < _HEADER_SIZE:
            self._done = True
            return List[WalRecord]()
        # An exception may leave the descriptor past a corrupt envelope. Do
        # not let a caught error turn a later read into accepted recovery.
        self._failed = True
        self._input.ensure_available(_HEADER_SIZE, self.valid_length)
        var record_size = _envelope_size(self._input.bytes(), self._dimension)
        if remaining < record_size:
            self._done = True
            self._failed = False
            return List[WalRecord]()
        self._input.ensure_available(record_size, self.valid_length)
        var records = _decode_envelope(
            self._input.bytes()[:record_size],
            self._dimension,
            self._previous_sequence,
        )
        self._previous_sequence = records[len(records) - 1].sequence
        self._input.consume(record_size)
        self.valid_length += record_size
        self._failed = False
        return records^

    def accepted_length(self) -> Int:
        return self.valid_length

    def total_length(self) -> Int:
        return self.source_length


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
    """Decode without modifying a missing file or accepted torn tail.

    This owned-result API retains decoded records, but never the complete
    encoded WAL or a copied repair prefix. Recovery can consume WalReader
    directly when it does not need to retain the complete history.
    """
    var reader = WalReader(path, dimension)
    var records = List[WalRecord]()
    while True:
        var batch = reader.read_next()
        if len(batch) == 0:
            break
        for var record in batch^:
            records.append(record^)
    return WalReplayState(records^, reader.valid_length, reader.source_length)


def repair_wal_tail(path: String, replay: WalReplayState) raises:
    """Apply only the tail repair established by ``preflight_wal``."""
    repair_wal_tail(path, replay.valid_length, replay.source_length)


def repair_wal_tail(path: String, valid_length: Int, source_length: Int) raises:
    """Truncate a preflighted WAL under the caller's collection exclusion.

    Never create a missing WAL or rewrite accepted bytes. Length changes since
    preflight are rejected before the first mutation. Complete all other source
    validation before calling this function.
    """
    comptime assert size_of[c_long]() == 8, "64-bit POSIX off_t required"
    if valid_length < 0 or valid_length > source_length:
        raise Error("invalid WAL repair length")
    if valid_length == source_length:
        return
    var file_path = path.copy()
    var descriptor = external_call["open", c_int, num_fixed_args=2](
        file_path.as_c_string_slice(), c_int(O_WRONLY | O_CLOEXEC)
    )
    if descriptor < 0:
        raise Error("open WAL for repair failed: " + String(get_errno()))
    var file = FileHandle()
    file.handle = Int(descriptor)
    if file.seek(0, SEEK_END) != UInt64(source_length):
        raise Error("WAL changed after preflight")
    if external_call["ftruncate", c_int](descriptor, c_long(valid_length)) != 0:
        raise Error("WAL tail truncate failed: " + String(get_errno()))
    sync_file(file)


def decode_wal_bytes(
    var bytes: List[UInt8], dimension: Int
) raises -> List[WalRecord]:
    return decode_wal_bytes(Span(bytes), dimension)


def decode_wal_bytes(
    bytes: Span[UInt8, _], dimension: Int
) raises -> List[WalRecord]:
    _validate_dimension(dimension)
    var records = List[WalRecord]()
    var offset = 0
    var previous_sequence = UInt64(0)
    while len(bytes) - offset >= _HEADER_SIZE:
        var record_size = _envelope_size(bytes[offset:], dimension)
        if len(bytes) - offset < record_size:
            break
        var batch = _decode_envelope(
            bytes[offset : offset + record_size], dimension, previous_sequence
        )
        previous_sequence = batch[len(batch) - 1].sequence
        for var record in batch^:
            records.append(record^)
        offset += record_size
    return records^


def _validate_dimension(dimension: Int) raises:
    if dimension <= 0 or dimension > Int(UInt32.MAX):
        raise Error("WAL dimension must be positive and fit UInt32")


def _envelope_size(bytes: Span[UInt8, _], dimension: Int) raises -> Int:
    # Both callers guarantee a complete 32-byte header. Preserve validation
    # order: bad magic/length fail even at EOF; other fields wait for a whole
    # envelope, so a torn final v3 batch yields none of its mutations.
    if not _has_magic(bytes):
        raise Error("invalid WAL record magic")
    var version = UInt16(bytes[4]) | (UInt16(bytes[5]) << UInt16(8))
    var maximum_size = 40 + dimension * 4 + MAX_PAYLOAD_BYTES
    if version == _VERSION_V3:
        maximum_size = _MAX_BATCH_BYTES
    var record_size = _read_u32_at(bytes, 8)
    if record_size < _MIN_RECORD_SIZE or record_size > maximum_size:
        raise Error("invalid WAL record length")
    return record_size


def _decode_envelope(
    bytes: Span[UInt8, _], dimension: Int, previous_sequence: UInt64
) raises -> List[WalRecord]:
    var records = List[WalRecord]()
    var version = UInt16(bytes[4]) | (UInt16(bytes[5]) << UInt16(8))
    if version == _VERSION_V3:
        if bytes[6] != _BATCH:
            raise Error("invalid WAL v3 operation")
        _ = _decode_batch(bytes, dimension, previous_sequence, records)
    else:
        var record = _decode_record(bytes, dimension)
        if record.sequence <= previous_sequence:
            raise Error("WAL sequence must increase")
        records.append(record^)
    return records^


def _decode_batch(
    bytes: Span[UInt8, _],
    expected_dimension: Int,
    previous_sequence: UInt64,
    mut records: List[WalRecord],
) raises -> UInt64:
    var encoded_size = len(bytes)
    var stored_checksum = _read_u32_at(bytes, encoded_size - 4)
    if ~crc32_update(CRC32_INITIAL, bytes[4 : encoded_size - 4]) != UInt32(
        stored_checksum
    ):
        raise Error("WAL checksum mismatch")

    var reader = BorrowedBinaryReader(bytes)
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
        var values = reader.read_f32s(dimension)
        var payload_length = Int(reader.read_u32())
        if mutation_size != dimension * 4 + 4 + payload_length:
            raise Error("WAL batch mutation length mismatch")
        var payload = reader.read_span(payload_length)
        var fields = decode_payload(payload)
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
    bytes: Span[UInt8, _], expected_dimension: Int
) raises -> WalRecord:
    var encoded_size = len(bytes)
    var stored_checksum = _read_u32_at(bytes, len(bytes) - 4)
    if ~crc32_update(CRC32_INITIAL, bytes[4 : len(bytes) - 4]) != UInt32(
        stored_checksum
    ):
        raise Error("WAL checksum mismatch")

    var reader = BorrowedBinaryReader(bytes)
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

    var values = List[Float32]()
    if operation == _UPSERT:
        values = reader.read_f32s(dimension)
    var fields = List[DocumentField]()
    if version == _VERSION_V2:
        var payload_length = Int(reader.read_u32())
        if operation == _DELETE and payload_length != 0:
            raise Error("WAL delete cannot contain payload")
        var payload = reader.read_span(payload_length)
        if operation == _UPSERT:
            fields = decode_payload(payload)
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected WAL payload")
    return WalRecord.with_fields(
        sequence, id, operation == _DELETE, values^, fields^
    )


def _has_magic(bytes: Span[UInt8, _]) -> Bool:
    return (
        bytes[0] == _MAGIC_0
        and bytes[1] == _MAGIC_1
        and bytes[2] == _MAGIC_2
        and bytes[3] == _MAGIC_3
    )


def _read_u32_at(bytes: Span[UInt8, _], offset: Int) -> Int:
    return Int(
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )
