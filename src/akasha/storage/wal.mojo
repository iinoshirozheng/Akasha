from akasha.storage.checksum import (
    BinaryReader,
    BinaryWriter,
    crc32_range,
)
from akasha.storage.filesystem import (
    append_file_sync,
    path_exists,
    read_file_bytes,
)


comptime _MAGIC_0 = UInt8(0x41)  # A
comptime _MAGIC_1 = UInt8(0x4B)  # K
comptime _MAGIC_2 = UInt8(0x57)  # W
comptime _MAGIC_3 = UInt8(0x4C)  # L
comptime _VERSION = UInt16(1)
comptime _UPSERT = UInt8(1)
comptime _DELETE = UInt8(2)
comptime _HEADER_SIZE = 32
comptime _MIN_RECORD_SIZE = 36


struct WalRecord(Movable):
    """One decoded, checksummed mutation."""

    var sequence: UInt64
    var id: Int
    var is_delete: Bool
    var values: List[Float32]

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

    @staticmethod
    def upsert(
        sequence: UInt64, id: Int, var values: List[Float32]
    ) -> WalRecord:
        return WalRecord(sequence, id, False, values^)

    @staticmethod
    def delete(sequence: UInt64, id: Int) -> WalRecord:
        return WalRecord(sequence, id, True, List[Float32]())


def encode_upsert(
    sequence: UInt64,
    id: Int,
    dimension: Int,
    values: List[Float32],
) raises -> List[UInt8]:
    if dimension <= 0 or len(values) != dimension:
        raise Error("WAL upsert dimension mismatch")
    return _encode_record(sequence, id, dimension, _UPSERT, values)


def encode_delete(
    sequence: UInt64, id: Int, dimension: Int
) raises -> List[UInt8]:
    if dimension <= 0:
        raise Error("WAL dimension must be positive")
    var empty = List[Float32]()
    return _encode_record(sequence, id, dimension, _DELETE, empty)


def append_wal(path: String, dimension: Int, record: WalRecord) raises:
    var bytes: List[UInt8]
    if record.is_delete:
        bytes = encode_delete(record.sequence, record.id, dimension)
    else:
        bytes = encode_upsert(
            record.sequence, record.id, dimension, record.values
        )
    append_file_sync(path, bytes)


def replay_wal(path: String, dimension: Int) raises -> List[WalRecord]:
    if not path_exists(path):
        return List[WalRecord]()
    var bytes = read_file_bytes(path)
    return decode_wal_bytes(bytes^, dimension)


def decode_wal_bytes(
    var bytes: List[UInt8], dimension: Int
) raises -> List[WalRecord]:
    if dimension <= 0:
        raise Error("WAL dimension must be positive")

    var records = List[WalRecord]()
    var offset = 0
    var previous_sequence = UInt64(0)
    var maximum_size = _MIN_RECORD_SIZE + dimension * 4

    while offset < len(bytes):
        var remaining = len(bytes) - offset
        if remaining < _HEADER_SIZE:
            break
        if not _has_magic(bytes, offset):
            raise Error("invalid WAL record magic")

        var record_size = _read_u32_at(bytes, offset + 8)
        if record_size < _MIN_RECORD_SIZE or record_size > maximum_size:
            raise Error("invalid WAL record length")
        if remaining < record_size:
            break

        var encoded = _copy_range(bytes, offset, offset + record_size)
        var record = _decode_record(encoded^, dimension)
        if record.sequence <= previous_sequence:
            raise Error("WAL sequence must increase")
        previous_sequence = record.sequence
        records.append(record^)
        offset += record_size

    return records^


def _encode_record(
    sequence: UInt64,
    id: Int,
    dimension: Int,
    operation: UInt8,
    values: List[Float32],
) raises -> List[UInt8]:
    if sequence == 0:
        raise Error("WAL sequence must be positive")
    var payload_size = 0 if operation == _DELETE else dimension * 4
    var record_size = _MIN_RECORD_SIZE + payload_size

    var writer = BinaryWriter()
    writer.write_u8(_MAGIC_0)
    writer.write_u8(_MAGIC_1)
    writer.write_u8(_MAGIC_2)
    writer.write_u8(_MAGIC_3)
    writer.write_u16(_VERSION)
    writer.write_u8(operation)
    writer.write_u8(0)
    writer.write_u32(UInt32(record_size))
    writer.write_u64(sequence)
    writer.write_i64(Int64(id))
    writer.write_u32(UInt32(dimension))
    if operation == _UPSERT:
        for value in values:
            writer.write_f32(value)

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
    if reader.read_u16() != _VERSION:
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
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected WAL payload")
    return WalRecord(sequence, id, operation == _DELETE, values^)


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
