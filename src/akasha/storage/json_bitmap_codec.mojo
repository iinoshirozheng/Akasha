"""Versioned bounded JSON bitmap payload for Akasha's derived cache envelope."""
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.index.lance_bitmap import LanceBitmapIndex
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.roaring_rows import RoaringRowSet
from akasha.storage.checksum import BinaryWriter, BorrowedBinaryReader
from akasha.query.control import QueryControl


def _write_text(mut writer: BinaryWriter, value: String):
    writer.write_u32(UInt32(value.byte_length()))
    for byte in value.as_bytes():
        writer.write_u8(byte)


def _read_text(mut reader: BorrowedBinaryReader[_]) raises -> String:
    var length = Int(reader.read_u32())
    return String(from_utf8=reader.read_span(length))


def encode_json_bitmap(column: String, index: LanceJsonBitmapIndex,
                       control: Optional[QueryControl] = None) raises -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_u16(1)
    writer.write_u8(index.target())
    writer.write_u8(UInt8(1 if index._string_getter_safe else 0))
    _write_text(writer, column)
    _write_text(writer, index.path)
    writer.write_u32(UInt32(len(index._bitmap._keys)))
    writer.write_u32(UInt32(index._bitmap._rows))
    for slot in range(len(index._bitmap._keys)+1):
        if control:
            control.value().checkpoint(slot)
        if slot > 0:
            ref key = index._bitmap._keys[slot-1]
            if index.target() <= 2:
                writer.write_i64(key._integer)
            elif index.target() == 3:
                writer.write_u64(key._bits)
            else:
                writer.write_u32(UInt32(len(key._bytes)))
                writer.write_bytes(key._bytes)
        var values = index._bitmap._nulls.values(control=control.copy()) if slot == 0 else index._bitmap._postings[slot-1].values(control=control.copy())
        writer.write_u32(UInt32(len(values)))
        for id in values:
            writer.write_u64(id)
    return writer.take_bytes()


def decode_json_bitmap(bytes: Span[UInt8, _], column: String, path: String,
                       target: UInt8, expected_rows: Int,
                       control: Optional[QueryControl] = None) raises -> LanceJsonBitmapIndex:
    if len(bytes) > 128 * 1024 * 1024:
        raise Error("JSON bitmap cache payload byte limit exceeded")
    var reader = BorrowedBinaryReader(bytes)
    if reader.read_u16() != 1 or reader.read_u8() != target:
        raise Error("JSON bitmap cache version/type mismatch")
    var safe = reader.read_u8()
    if safe > 1:
        raise Error("JSON bitmap cache invalid provenance")
    if _read_text(reader) != column or _read_text(reader) != path:
        raise Error("JSON bitmap cache definition mismatch")
    var count = Int(reader.read_u32())
    var rows = Int(reader.read_u32())
    if rows != expected_rows or rows > 1_000_000 or count > rows:
        raise Error("JSON bitmap cache count mismatch")
    if control:
        control.value().validate_candidate_count(rows)
    var bitmap = LanceBitmapIndex(target)
    var seen = RoaringRowSet()
    for slot in range(count+1):
        if control:
            control.value().checkpoint(slot)
        var key = LanceScalarKey.null(target)
        if slot > 0:
            if target <= 2:
                var integer = reader.read_i64()
                if target == 1 and integer != 0 and integer != 1:
                    raise Error("JSON bitmap cache invalid Boolean")
                key = LanceScalarKey.boolean(integer == 1) if target == 1 else LanceScalarKey.integer(integer)
            elif target == 3:
                key = LanceScalarKey.float_bits(reader.read_u64())
            else:
                var length = Int(reader.read_u32())
                if length > 64 * 1024 * 1024:
                    raise Error("JSON bitmap cache key byte limit exceeded")
                var value = List[UInt8]()
                value.extend(reader.read_span(length))
                if target == 4:
                    _ = String(from_utf8=Span(value))
                key = LanceScalarKey.binary(value^)
                key.target = target
            if slot > 1 and bitmap._keys[len(bitmap._keys)-1].compare(key) >= 0:
                raise Error("JSON bitmap cache keys are not ordered")
        var cardinality = Int(reader.read_u32())
        if cardinality > rows or (slot > 0 and cardinality == 0):
            raise Error("JSON bitmap cache invalid posting count")
        var posting = RoaringRowSet()
        var previous = UInt64(0)
        for ordinal in range(cardinality):
            if control:
                control.value().checkpoint(ordinal)
            var id = reader.read_u64()
            if id >= UInt64(rows) or (ordinal > 0 and id <= previous) or seen.contains(id):
                raise Error("JSON bitmap cache invalid row ordinal")
            _ = seen.insert(id)
            _ = posting.insert(id)
            previous = id
        bitmap._emit(key, posting^)
    if reader.remaining() != 0 or bitmap._rows != rows:
        raise Error("JSON bitmap cache length/coverage mismatch")
    return LanceJsonBitmapIndex(path.copy(), bitmap^, safe == 1)
