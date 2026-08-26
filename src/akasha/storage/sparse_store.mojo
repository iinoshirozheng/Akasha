from akasha.index.sparse import (
    SparseElement,
    SparseRecord,
    validate_sparse,
)
from akasha.storage.checksum import BinaryReader, BinaryWriter, crc32_range
from akasha.storage.filesystem import (
    append_file_sync,
    atomic_replace,
    path_exists,
    read_file_bytes,
    sync_directory,
    write_file_sync,
)


comptime _SNAPSHOT_MAGIC_2 = UInt8(0x50)  # P
comptime _WAL_MAGIC_2 = UInt8(0x57)  # W
comptime _MAGIC_0 = UInt8(0x41)  # A
comptime _MAGIC_1 = UInt8(0x4B)  # K
comptime _MAGIC_3 = UInt8(0x52)  # R
comptime _VERSION = UInt16(1)
comptime _SEGMENT_VERSION = UInt16(2)
comptime _UPSERT = UInt8(1)
comptime _DELETE = UInt8(2)
comptime _WAL_FIXED_SIZE = 36
comptime SPARSE_SEGMENT_KIND_BASE = 1
comptime SPARSE_SEGMENT_KIND_DELTA = 2


struct SparseWalRecord(Movable):
    var sequence: UInt64
    var id: Int
    var is_delete: Bool
    var elements: List[SparseElement]

    def __init__(
        out self,
        sequence: UInt64,
        id: Int,
        is_delete: Bool,
        var elements: List[SparseElement],
    ):
        self.sequence = sequence
        self.id = id
        self.is_delete = is_delete
        self.elements = elements^

    @staticmethod
    def upsert(
        sequence: UInt64, id: Int, var elements: List[SparseElement]
    ) -> SparseWalRecord:
        return SparseWalRecord(sequence, id, False, elements^)

    @staticmethod
    def delete(sequence: UInt64, id: Int) -> SparseWalRecord:
        return SparseWalRecord(sequence, id, True, List[SparseElement]())

    def clone(self) -> SparseWalRecord:
        var elements = self.elements.copy()
        return SparseWalRecord(
            self.sequence, self.id, self.is_delete, elements^
        )


struct SparseSegment(Movable):
    var kind: Int
    var min_sequence: UInt64
    var last_sequence: UInt64
    var checksum: UInt32
    var records: List[SparseWalRecord]

    def __init__(
        out self,
        kind: Int,
        min_sequence: UInt64,
        last_sequence: UInt64,
        checksum: UInt32,
        var records: List[SparseWalRecord],
    ):
        self.kind = kind
        self.min_sequence = min_sequence
        self.last_sequence = last_sequence
        self.checksum = checksum
        self.records = records^


def latest_sparse_records(
    records: List[SparseWalRecord],
) raises -> List[SparseWalRecord]:
    """Collapse ordered mutations to the newest state for each point ID."""
    var latest = List[SparseWalRecord]()
    var previous_sequence = UInt64(0)
    for index in range(len(records)):
        if records[index].sequence == 0:
            raise Error("sparse mutation sequence must be positive")
        if index > 0 and records[index].sequence <= previous_sequence:
            raise Error("sparse mutation sequences must increase")
        previous_sequence = records[index].sequence
        if records[index].is_delete:
            if len(records[index].elements) != 0:
                raise Error("sparse delete cannot contain elements")
        else:
            validate_sparse(records[index].elements)
        var found = -1
        for latest_index in range(len(latest)):
            if latest[latest_index].id == records[index].id:
                found = latest_index
                break
        if found >= 0:
            latest[found] = records[index].clone()
        else:
            latest.append(records[index].clone())

    for index in range(1, len(latest)):
        var cursor = index
        while cursor > 0 and latest[cursor].id < latest[cursor - 1].id:
            latest.swap_elements(cursor, cursor - 1)
            cursor -= 1
    return latest^


def write_sparse_segment(
    path: String,
    kind: Int,
    min_sequence: UInt64,
    max_sequence: UInt64,
    records: List[SparseWalRecord],
) raises -> UInt32:
    var bytes = encode_sparse_segment(kind, min_sequence, max_sequence, records)
    var checksum = UInt32(_read_u32_at(bytes, len(bytes) - 4))
    write_file_sync(path, bytes)
    return checksum


def encode_sparse_segment(
    kind: Int,
    min_sequence: UInt64,
    max_sequence: UInt64,
    records: List[SparseWalRecord],
) raises -> List[UInt8]:
    if kind != SPARSE_SEGMENT_KIND_BASE and kind != SPARSE_SEGMENT_KIND_DELTA:
        raise Error("unsupported sparse segment kind")
    if min_sequence > max_sequence:
        raise Error("sparse segment sequence range is invalid")
    var ordered = List[SparseWalRecord](capacity=len(records))
    for index in range(len(records)):
        if (
            records[index].sequence == 0
            or records[index].sequence < min_sequence
            or records[index].sequence > max_sequence
        ):
            raise Error("invalid sparse segment record sequence")
        if records[index].is_delete:
            if kind == SPARSE_SEGMENT_KIND_BASE:
                raise Error("sparse base segment cannot contain deletes")
            if len(records[index].elements) != 0:
                raise Error("sparse delete cannot contain elements")
        else:
            validate_sparse(records[index].elements)
        ordered.append(records[index].clone())
    for index in range(1, len(ordered)):
        var cursor = index
        while cursor > 0 and ordered[cursor].id < ordered[cursor - 1].id:
            ordered.swap_elements(cursor, cursor - 1)
            cursor -= 1
    for index in range(1, len(ordered)):
        if ordered[index].id == ordered[index - 1].id:
            raise Error("sparse segment point IDs must be unique")

    var writer = BinaryWriter()
    _write_magic(writer, _SNAPSHOT_MAGIC_2)
    writer.write_u16(_SEGMENT_VERSION)
    writer.write_u16(UInt16(kind))
    writer.write_u64(UInt64(len(ordered)))
    writer.write_u64(min_sequence)
    writer.write_u64(max_sequence)
    for index in range(len(ordered)):
        writer.write_i64(Int64(ordered[index].id))
        writer.write_u64(ordered[index].sequence)
        writer.write_u8(_DELETE if ordered[index].is_delete else _UPSERT)
        writer.write_u8(0)
        writer.write_u16(0)
        writer.write_u32(UInt32(len(ordered[index].elements)))
        _write_elements(writer, ordered[index].elements)
    return _finish_checksum(writer)


def read_sparse_segment(path: String) raises -> SparseSegment:
    var bytes = read_file_bytes(path)
    if len(bytes) < 36:
        raise Error("truncated sparse segment")
    _validate_checksum(bytes)
    var stored_checksum = UInt32(_read_u32_at(bytes, len(bytes) - 4))
    var encoded_size = len(bytes)
    var reader = BinaryReader(bytes^)
    _read_magic(reader, _SNAPSHOT_MAGIC_2)
    if reader.read_u16() != _SEGMENT_VERSION:
        raise Error("unsupported sparse segment version")
    var kind = Int(reader.read_u16())
    if kind != SPARSE_SEGMENT_KIND_BASE and kind != SPARSE_SEGMENT_KIND_DELTA:
        raise Error("unsupported sparse segment kind")
    var count_u64 = reader.read_u64()
    if count_u64 > UInt64(Int.MAX):
        raise Error("sparse segment record count is too large")
    var count = Int(count_u64)
    if count > (encoded_size - 36) // 24:
        raise Error("sparse segment record count exceeds file length")
    var min_sequence = reader.read_u64()
    var max_sequence = reader.read_u64()
    if min_sequence > max_sequence:
        raise Error("sparse segment sequence range is invalid")
    var records = List[SparseWalRecord](capacity=count)
    var previous_id = 0
    for index in range(count):
        var id = Int(reader.read_i64())
        if index > 0 and id <= previous_id:
            raise Error("sparse segment point IDs must increase")
        previous_id = id
        var sequence = reader.read_u64()
        if sequence == 0 or sequence < min_sequence or sequence > max_sequence:
            raise Error("invalid sparse segment record sequence")
        var operation = reader.read_u8()
        if operation != _UPSERT and operation != _DELETE:
            raise Error("invalid sparse segment operation")
        if reader.read_u8() != 0 or reader.read_u16() != 0:
            raise Error("unsupported sparse segment record flags")
        var elements = _read_elements(reader)
        if operation == _DELETE:
            if kind == SPARSE_SEGMENT_KIND_BASE:
                raise Error("sparse base segment cannot contain deletes")
            if len(elements) != 0:
                raise Error("sparse delete cannot contain elements")
        records.append(
            SparseWalRecord(sequence, id, operation == _DELETE, elements^)
        )
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected sparse segment payload")
    return SparseSegment(
        kind,
        min_sequence,
        max_sequence,
        stored_checksum,
        records^,
    )


def write_sparse_snapshot(
    path: String, last_sequence: UInt64, records: List[SparseRecord]
) raises -> UInt32:
    var bytes = encode_sparse_snapshot(last_sequence, records)
    var checksum = UInt32(_read_u32_at(bytes, len(bytes) - 4))
    write_file_sync(path, bytes)
    return checksum


def encode_sparse_snapshot(
    last_sequence: UInt64, records: List[SparseRecord]
) raises -> List[UInt8]:
    if len(records) > 0 and last_sequence == 0:
        raise Error("non-empty sparse snapshot requires a sequence")
    var ordered = List[SparseRecord](capacity=len(records))
    for index in range(len(records)):
        validate_sparse(records[index].elements)
        ordered.append(records[index].clone())
    for index in range(1, len(ordered)):
        var cursor = index
        while cursor > 0 and ordered[cursor].id < ordered[cursor - 1].id:
            ordered.swap_elements(cursor, cursor - 1)
            cursor -= 1
    for index in range(1, len(ordered)):
        if ordered[index].id == ordered[index - 1].id:
            raise Error("sparse snapshot point IDs must be unique")

    var writer = BinaryWriter()
    _write_magic(writer, _SNAPSHOT_MAGIC_2)
    writer.write_u16(_VERSION)
    writer.write_u16(0)
    writer.write_u64(UInt64(len(ordered)))
    writer.write_u64(last_sequence)
    for index in range(len(ordered)):
        writer.write_i64(Int64(ordered[index].id))
        writer.write_u32(UInt32(len(ordered[index].elements)))
        _write_elements(writer, ordered[index].elements)
    return _finish_checksum(writer)


def read_sparse_snapshot(
    path: String, expected_sequence: UInt64
) raises -> List[SparseRecord]:
    var bytes = read_file_bytes(path)
    if len(bytes) < 28:
        raise Error("truncated sparse snapshot")
    _validate_checksum(bytes)
    var reader = BinaryReader(bytes^)
    _read_magic(reader, _SNAPSHOT_MAGIC_2)
    if reader.read_u16() != _VERSION or reader.read_u16() != 0:
        raise Error("unsupported sparse snapshot format")
    var count_u64 = reader.read_u64()
    if count_u64 > UInt64(Int.MAX):
        raise Error("sparse snapshot record count is too large")
    var count = Int(count_u64)
    var sequence = reader.read_u64()
    if sequence != expected_sequence:
        raise Error("sparse snapshot sequence mismatch")
    var records = List[SparseRecord](capacity=count)
    var previous_id = 0
    for index in range(count):
        var id = Int(reader.read_i64())
        if index > 0 and id <= previous_id:
            raise Error("sparse snapshot point IDs must increase")
        previous_id = id
        var elements = _read_elements(reader)
        records.append(SparseRecord(id, elements^))
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected sparse snapshot payload")
    return records^


def append_sparse_wal(path: String, record: SparseWalRecord) raises:
    var bytes = encode_sparse_wal_record(record)
    append_file_sync(path, bytes)


def encode_sparse_wal_record(record: SparseWalRecord) raises -> List[UInt8]:
    if record.sequence == 0:
        raise Error("sparse WAL sequence must be positive")
    if record.is_delete:
        if len(record.elements) != 0:
            raise Error("sparse WAL delete cannot contain elements")
    else:
        validate_sparse(record.elements)
    var size = _WAL_FIXED_SIZE + len(record.elements) * 12
    var writer = BinaryWriter()
    _write_magic(writer, _WAL_MAGIC_2)
    writer.write_u16(_VERSION)
    writer.write_u8(_DELETE if record.is_delete else _UPSERT)
    writer.write_u8(0)
    writer.write_u32(UInt32(size))
    writer.write_u64(record.sequence)
    writer.write_i64(Int64(record.id))
    writer.write_u32(UInt32(len(record.elements)))
    _write_elements(writer, record.elements)
    return _finish_checksum(writer)


def recover_sparse_wal(path: String) raises -> List[SparseWalRecord]:
    if not path_exists(path):
        return List[SparseWalRecord]()
    var bytes = read_file_bytes(path)
    var records = decode_sparse_wal_bytes(bytes)
    var valid_length = 0
    for index in range(len(records)):
        valid_length += _WAL_FIXED_SIZE + len(records[index].elements) * 12
    if valid_length < len(bytes):
        var prefix = List[UInt8](capacity=valid_length)
        for index in range(valid_length):
            prefix.append(bytes[index])
        write_file_sync(path, prefix)
    return records^


def decode_sparse_wal_bytes(bytes: List[UInt8]) raises -> List[SparseWalRecord]:
    var records = List[SparseWalRecord]()
    var offset = 0
    var previous_sequence = UInt64(0)
    while offset < len(bytes):
        if len(bytes) - offset < 32:
            break
        if not _has_magic(bytes, offset, _WAL_MAGIC_2):
            raise Error("invalid sparse WAL magic")
        var size = _read_u32_at(bytes, offset + 8)
        if size < _WAL_FIXED_SIZE:
            raise Error("invalid sparse WAL record size")
        if len(bytes) - offset < size:
            break
        var encoded = List[UInt8](capacity=size)
        for index in range(offset, offset + size):
            encoded.append(bytes[index])
        var record = _decode_sparse_wal_record(encoded^)
        if record.sequence <= previous_sequence:
            raise Error("sparse WAL sequence must increase")
        previous_sequence = record.sequence
        records.append(record^)
        offset += size
    return records^


def rotate_sparse_wal(directory: String) raises:
    var temporary_path = directory + "/sparse.wal.tmp"
    var empty = List[UInt8]()
    write_file_sync(temporary_path, empty)
    atomic_replace(temporary_path, directory + "/sparse.wal")
    sync_directory(directory)


def _decode_sparse_wal_record(var bytes: List[UInt8]) raises -> SparseWalRecord:
    _validate_checksum(bytes)
    var encoded_size = len(bytes)
    var reader = BinaryReader(bytes^)
    _read_magic(reader, _WAL_MAGIC_2)
    if reader.read_u16() != _VERSION:
        raise Error("unsupported sparse WAL version")
    var operation = reader.read_u8()
    if operation != _UPSERT and operation != _DELETE:
        raise Error("invalid sparse WAL operation")
    if reader.read_u8() != 0 or Int(reader.read_u32()) != encoded_size:
        raise Error("invalid sparse WAL header")
    var sequence = reader.read_u64()
    if sequence == 0:
        raise Error("sparse WAL sequence must be positive")
    var id = Int(reader.read_i64())
    var elements = _read_elements(reader)
    if operation == _DELETE and len(elements) != 0:
        raise Error("sparse WAL delete cannot contain elements")
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected sparse WAL payload")
    return SparseWalRecord(sequence, id, operation == _DELETE, elements^)


def _write_elements(mut writer: BinaryWriter, elements: List[SparseElement]):
    for element in elements:
        writer.write_i64(Int64(element.term_id))
        writer.write_f32(element.weight)


def _read_elements(mut reader: BinaryReader) raises -> List[SparseElement]:
    var count = Int(reader.read_u32())
    if count > reader.remaining() // 12:
        raise Error("sparse element count exceeds record length")
    var elements = List[SparseElement](capacity=count)
    for _ in range(count):
        elements.append(
            SparseElement(Int(reader.read_i64()), reader.read_f32())
        )
    if count > 0:
        validate_sparse(elements)
    return elements^


def _write_magic(mut writer: BinaryWriter, third: UInt8):
    writer.write_u8(_MAGIC_0)
    writer.write_u8(_MAGIC_1)
    writer.write_u8(third)
    writer.write_u8(_MAGIC_3)


def _read_magic(mut reader: BinaryReader, third: UInt8) raises:
    if (
        reader.read_u8() != _MAGIC_0
        or reader.read_u8() != _MAGIC_1
        or reader.read_u8() != third
        or reader.read_u8() != _MAGIC_3
    ):
        raise Error("invalid sparse storage magic")


def _finish_checksum(mut writer: BinaryWriter) -> List[UInt8]:
    var body = writer.take_bytes()
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def _validate_checksum(bytes: List[UInt8]) raises:
    if len(bytes) < 4:
        raise Error("truncated sparse storage value")
    var stored = UInt32(_read_u32_at(bytes, len(bytes) - 4))
    if crc32_range(bytes, 4, len(bytes) - 4) != stored:
        raise Error("sparse storage checksum mismatch")


def _has_magic(bytes: List[UInt8], offset: Int, third: UInt8) -> Bool:
    return (
        bytes[offset] == _MAGIC_0
        and bytes[offset + 1] == _MAGIC_1
        and bytes[offset + 2] == third
        and bytes[offset + 3] == _MAGIC_3
    )


def _read_u32_at(bytes: List[UInt8], offset: Int) -> Int:
    return Int(
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )
