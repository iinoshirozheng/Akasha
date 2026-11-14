"""Versioned bounded JSON bitmap payload for Akasha's derived cache envelope."""
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.index.lance_bitmap import LanceBitmapIndex
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.roaring_rows import RoaringRowSet, _Container, _Roaring32
from akasha.storage.checksum import BinaryWriter, BorrowedBinaryReader, BinaryReaderSource
from akasha.storage.index_cache import MappedCacheArtifact
from akasha.index.mapped_postings import MappedPostings, PostingLocation
from std.memory import ArcPointer
from std.sys import size_of
from akasha.query.control import QueryControl


def _write_text(mut writer: BinaryWriter, value: String):
    writer.write_u32(UInt32(value.byte_length()))
    for byte in value.as_bytes():
        writer.write_u8(byte)


def _read_text[Reader: BinaryReaderSource](mut reader: Reader) raises -> String:
    var length = Int(reader.read_u32())
    var bytes = reader.read_bytes(length)
    return String(from_utf8=Span(bytes))


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
            _write_bitmap_key(writer, key)
        var values = index._bitmap.null_rows(control).values(control=control.copy()) if slot == 0 else index._bitmap.posting(slot-1, control).values(control=control.copy())
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
    return _decode_bitmap(reader, column, path, target, expected_rows, control)


def map_json_bitmap(var artifact: MappedCacheArtifact, column: String, path: String,
                    target: UInt8, expected_rows: Int,
                    control: Optional[QueryControl] = None, *,
                    cache_bytes: Int = 8 * 1024 * 1024,
                    cache_entries: Int = 128) raises -> LanceJsonBitmapIndex:
    return map_shared_json_bitmap(ArcPointer(artifact^), column, path, target,
        expected_rows, control, cache_bytes=cache_bytes, cache_entries=cache_entries)


def map_shared_json_bitmap(artifact: ArcPointer[MappedCacheArtifact], column: String, path: String,
                    target: UInt8, expected_rows: Int,
                    control: Optional[QueryControl] = None, *,
                    cache_bytes: Int = 8 * 1024 * 1024,
                    cache_entries: Int = 128) raises -> LanceJsonBitmapIndex:
    if artifact[].payload_length > 128 * 1024 * 1024:
        raise Error("JSON bitmap cache payload byte limit exceeded")
    var store = ArcPointer(MappedPostings(artifact.copy(),
        max_bytes=cache_bytes, max_entries=cache_entries))
    from akasha.storage.mapped_reader import MappedBinaryReader
    var reader = MappedBinaryReader(Pointer(to=store[].artifact[]._mapping), 36, artifact[].payload_length)
    return _decode_bitmap(reader, column, path, target, expected_rows, control, Optional(store.copy()))


def _decode_bitmap[Reader: BinaryReaderSource](mut reader: Reader, column: String,
                   path: String, target: UInt8, expected_rows: Int,
                   control: Optional[QueryControl],
                   mapped: Optional[ArcPointer[MappedPostings]] = None) raises -> LanceJsonBitmapIndex:
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
    var seen = List[UInt8](length=(rows + 7) // 8, fill=0)
    var covered = 0
    var logical_bytes = 0
    for slot in range(count+1):
        if control:
            control.value().checkpoint(slot)
        var key = LanceScalarKey.null(target)
        if slot > 0:
            key = _read_bitmap_key(reader, target)
            if slot > 1 and bitmap._keys[len(bitmap._keys)-1].compare(key) >= 0:
                raise Error("JSON bitmap cache keys are not ordered")
        var cardinality = Int(reader.read_u32())
        if cardinality > rows or (slot > 0 and cardinality == 0):
            raise Error("JSON bitmap cache invalid posting count")
        if cardinality > reader.remaining() // 8:
            raise Error("JSON bitmap cache truncated posting")
        if mapped:
            mapped.value()[].locations.append(PostingLocation(36 + reader.position(), cardinality))
        var posting = RoaringRowSet()
        var previous = UInt64(0)
        var container_count = 0
        var posting_bytes = size_of[UInt32]() + size_of[_Roaring32]() if cardinality else 0
        for ordinal in range(cardinality):
            if control:
                control.value().checkpoint(ordinal)
            var id = reader.read_u64()
            if id >= UInt64(rows) or (ordinal > 0 and id <= previous):
                raise Error("JSON bitmap cache invalid row ordinal")
            var byte = Int(id) // 8
            var bit = UInt8(1) << UInt8(Int(id) % 8)
            if seen[byte] & bit:
                raise Error("JSON bitmap cache duplicate row ordinal")
            seen[byte] |= bit
            covered += 1
            if not mapped:
                _ = posting.insert(id)
            # Dense row ordinals fit one UInt32 map. Count Roaring array/bitmap
            # storage without constructing any containers during mapped open.
            if ordinal == 0 or (id >> 16) != (previous >> 16):
                posting_bytes += size_of[_Container]()
                container_count = 0
            if container_count < 4096:
                posting_bytes += 2
            container_count += 1
            previous = id
        logical_bytes += posting_bytes
        if not key.is_null:
            logical_bytes += size_of[LanceScalarKey]() + size_of[RoaringRowSet]() + len(key._bytes)
        bitmap._check(covered, logical_bytes)
        if mapped:
            bitmap._rows += cardinality
            bitmap._bytes += size_of[PostingLocation]()
            if not key.is_null:
                bitmap._bytes += size_of[LanceScalarKey]() + len(key._bytes)
                bitmap._keys.append(key^)
            bitmap._check(bitmap._rows, bitmap._bytes)
        else:
            bitmap._emit(key, posting^)
    if reader.remaining() != 0 or covered != rows:
        raise Error("JSON bitmap cache length/coverage mismatch")
    bitmap._mapped = mapped.copy()
    return LanceJsonBitmapIndex(path.copy(), bitmap^, safe == 1)


def _read_bitmap_key[Reader: BinaryReaderSource](mut reader: Reader, target: UInt8) raises -> LanceScalarKey:
    var key = LanceScalarKey.null(target)
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
        var value = reader.read_bytes(length)
        if target == 4:
            _ = String(from_utf8=Span(value))
        key = LanceScalarKey.binary(value^)
        key.target = target
    return key^


def _write_bitmap_key(mut writer: BinaryWriter, key: LanceScalarKey):
    if key.target <= 2:
        writer.write_i64(key._integer)
    elif key.target == 3:
        writer.write_u64(key._bits)
    else:
        writer.write_u32(UInt32(len(key._bytes)))
        writer.write_bytes(key._bytes)
