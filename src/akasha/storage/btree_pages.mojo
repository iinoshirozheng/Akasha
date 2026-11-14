"""Immutable native B-tree leaves in an AKIC kind-6 derived artifact.

The directory is resident; leaves are decoded independently from the shared
mapping. Opening validates every row but retains no decoded leaf rows.
"""
from std.memory import ArcPointer
from std.sys import size_of
from akasha.index.lance_bitmap import LanceBitmapRow, BitmapRowStream
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_btree_lookup import LanceBTreeLookup, BTreePageStats
from akasha.index.roaring_rows import RoaringRowSet
from akasha.storage.checksum import BinaryWriter, BinaryReaderSource
from akasha.storage.json_bitmap_codec import _read_bitmap_key, _write_bitmap_key, _read_text, _write_text
from akasha.storage.index_cache import MappedCacheArtifact, CACHE_JSON_BTREE_KIND, encode_cache_header
from akasha.storage.mapped_reader import MappedBinaryReader
from akasha.storage.mapped_file import MappedFile
from akasha.storage.filesystem import create_anonymous_file
from akasha.storage.byte_sink import FileByteSink, CheckedByteSink, write_checksum
from akasha.query.control import QueryControl

comptime BTREE_PAGE_ROWS = 4096
comptime BTREE_PAGE_TARGET_BYTES = 8 * 1024 * 1024
comptime BTREE_MAX_BYTES = 128 * 1024 * 1024
comptime BTREE_MAX_PAGE_BYTES = 64 * 1024 * 1024


@fieldwise_init
struct BTreePageLocation(Copyable, Movable):
    var offset: Int
    var length: Int


def _write_key(mut writer: BinaryWriter, key: LanceScalarKey):
    writer.write_u8(UInt8(key.is_null))
    if not key.is_null:
        _write_bitmap_key(writer, key)


def _read_key[Reader: BinaryReaderSource](mut reader: Reader, target: UInt8) raises -> LanceScalarKey:
    var null = reader.read_u8()
    if null > 1:
        raise Error("invalid B-tree null tag")
    return LanceScalarKey.null(target) if null else _read_bitmap_key(reader, target)


def _read_row[Reader: BinaryReaderSource](mut reader: Reader, target: UInt8) raises -> LanceBitmapRow:
    var key = _read_key(reader, target)
    return LanceBitmapRow(key^, reader.read_u64())


@fieldwise_init
struct BTreePages(Copyable, Movable):
    var artifact: ArcPointer[MappedCacheArtifact]
    var lookup: LanceBTreeLookup
    var locations: List[BTreePageLocation]
    var row_count: Int
    var max_id: UInt64
    var column: String
    var path: String
    var string_getter_safe: Bool

    def read_page(self, page: Int, control: Optional[QueryControl] = None) raises -> List[LanceBitmapRow]:
        if page < 0 or page >= len(self.locations):
            raise Error("B-tree page index out of bounds")
        if control:
            control.value().checkpoint(0)
        ref location = self.locations[page]
        var reader = MappedBinaryReader(Pointer(to=self.artifact[]._mapping), location.offset, location.length)
        var result = List[LanceBitmapRow](capacity=self.lookup.pages[page].row_count)
        for i in range(self.lookup.pages[page].row_count):
            if control:
                control.value().checkpoint(i)
            result.append(_read_row(reader, self.lookup.target))
        if reader.remaining() != 0:
            raise Error("B-tree leaf length mismatch")
        return result^


def map_btree_pages(artifact: ArcPointer[MappedCacheArtifact], column: String,
                    path: String, target: UInt8, expected_rows: Int,
                    control: Optional[QueryControl] = None) raises -> BTreePages:
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(expected_rows)
    if artifact[].kind != CACHE_JSON_BTREE_KIND or artifact[].payload_length > BTREE_MAX_BYTES:
        raise Error("B-tree cache envelope mismatch")
    var reader = artifact[].payload_reader()
    if reader.read_u16() != 1 or reader.read_u8() != target:
        raise Error("B-tree cache version/type mismatch")
    _ = LanceScalarKey.null(target)
    var safe = reader.read_u8()
    if safe > 1:
        raise Error("B-tree cache invalid provenance")
    if _read_text(reader) != column or _read_text(reader) != path:
        raise Error("B-tree cache definition mismatch")
    var rows = Int(reader.read_u32())
    var count = Int(reader.read_u32())
    if rows != expected_rows or rows > 1_000_000 or count > rows or ((count == 0) != (rows == 0)):
        raise Error("B-tree cache count mismatch")
    var stats = List[BTreePageStats]()
    var locations = List[BTreePageLocation]()
    var offset = 0
    var total = 0
    var directory_bytes = 0
    for i in range(count):
        if control:
            control.value().checkpoint(i)
        var n = Int(reader.read_u32())
        var nulls = Int(reader.read_u32())
        var start = Int(reader.read_u32())
        var length = Int(reader.read_u32())
        if n <= 0 or n > BTREE_PAGE_ROWS or start != offset or length < n * 9 or length > BTREE_MAX_PAGE_BYTES:
            raise Error("invalid B-tree page location/cardinality")
        var minimum = _read_key(reader, target)
        var maximum = _read_key(reader, target)
        directory_bytes += size_of[BTreePageStats]() + size_of[BTreePageLocation]() + len(minimum._bytes) + len(maximum._bytes)
        if directory_bytes > 64 * 1024 * 1024:
            raise Error("B-tree directory byte limit exceeded")
        stats.append(BTreePageStats(minimum^, maximum^, nulls, n))
        locations.append(BTreePageLocation(start, length))
        offset += length
        total += n
        if offset > BTREE_MAX_BYTES or total > rows:
            raise Error("B-tree page totals exceed payload")
    if total != rows or reader.remaining() != offset:
        raise Error("B-tree cache length/coverage mismatch")
    var lookup = LanceBTreeLookup(target, stats^)
    var base = 36 + reader.position()
    var seen = RoaringRowSet()
    var previous = LanceScalarKey.null(target)
    var max_id = UInt64(0)
    var ordinal = 0
    for i in range(count):
        locations[i].offset += base
        var leaf = MappedBinaryReader(Pointer(to=artifact[]._mapping), locations[i].offset, locations[i].length)
        var nulls = 0
        for j in range(lookup.pages[i].row_count):
            if control:
                control.value().checkpoint(ordinal)
            var row = _read_row(leaf, target)
            if ordinal > 0 and previous.compare(row.key) > 0:
                raise Error("B-tree leaf values are not sorted")
            if not seen.insert(row.id):
                raise Error("B-tree duplicate row ID")
            if seen._bytes > 64 * 1024 * 1024:
                raise Error("B-tree row-ID validation byte limit exceeded")
            if j == 0 and row.key.compare(lookup.pages[i].minimum) != 0:
                raise Error("B-tree minimum does not match leaf")
            if j == lookup.pages[i].row_count - 1 and row.key.compare(lookup.pages[i].maximum) != 0:
                raise Error("B-tree maximum does not match leaf")
            if row.key.is_null:
                nulls += 1
            max_id = max(max_id, row.id)
            previous = row.key.copy()
            ordinal += 1
        if leaf.remaining() != 0 or nulls != lookup.pages[i].null_count:
            raise Error("B-tree leaf length/null count mismatch")
    return BTreePages(artifact.copy(), lookup^, locations^, rows, max_id, column.copy(), path.copy(), safe == 1)


def stage_btree_pages[Stream: BitmapRowStream](mut stream: Stream, column: String,
                     path: String, target: UInt8, string_getter_safe: Bool,
                     dimension: Int, sequence: UInt64, source_checksum: UInt32,
                     control: Optional[QueryControl] = None, *,
                     page_rows: Int = BTREE_PAGE_ROWS) raises -> BTreePages:
    """Consume sorted rows; bounded leaf staging plus a resident page directory."""
    _ = LanceScalarKey.null(target)
    if page_rows <= 0 or page_rows > BTREE_PAGE_ROWS:
        raise Error("invalid B-tree page row limit")
    if column.byte_length() + path.byte_length() > 16 * 1024 * 1024:
        raise Error("B-tree definition byte limit exceeded")
    var file = create_anonymous_file()
    var stats = List[BTreePageStats]()
    var locations = List[BTreePageLocation]()
    var length = 0
    var rows = 0
    var count = 0
    var nulls = 0
    var start = 0
    var minimum = LanceScalarKey.null(target)
    var maximum = LanceScalarKey.null(target)
    var directory_bytes = 0
    while True:
        if control:
            control.value().checkpoint(rows)
        var next_row = stream.next()
        if not next_row:
            break
        var row = next_row.take()
        row.key.validate(target)
        if rows >= 1_000_000:
            raise Error("B-tree row limit exceeded")
        if control:
            control.value().validate_candidate_count(rows + 1)
        if rows > 0 and maximum.compare(row.key) > 0:
            raise Error("B-tree input is not sorted")
        var writer = BinaryWriter()
        _write_key(writer, row.key)
        writer.write_u64(row.id)
        var encoded = writer.take_bytes()
        if len(encoded) > BTREE_MAX_PAGE_BYTES:
            raise Error("B-tree row byte limit exceeded")
        if count > 0 and (count == page_rows or length - start + len(encoded) > BTREE_PAGE_TARGET_BYTES):
            stats.append(BTreePageStats(minimum.copy(), maximum.copy(), nulls, count))
            locations.append(BTreePageLocation(start, length-start))
            directory_bytes += size_of[BTreePageStats]() + size_of[BTreePageLocation]() + len(minimum._bytes) + len(maximum._bytes)
            if directory_bytes > 64 * 1024 * 1024:
                raise Error("B-tree directory byte limit exceeded")
            count = 0
            nulls = 0
            start = length
        if count == 0:
            minimum = row.key.copy()
        maximum = row.key.copy()
        if maximum.is_null:
            nulls += 1
        count += 1
        rows += 1
        length += len(encoded)
        if length > BTREE_MAX_BYTES:
            raise Error("B-tree payload byte limit exceeded")
        file.write_all(encoded)
    if count:
        stats.append(BTreePageStats(minimum.copy(), maximum.copy(), nulls, count))
        locations.append(BTreePageLocation(start, length-start))
        directory_bytes += size_of[BTreePageStats]() + size_of[BTreePageLocation]() + len(minimum._bytes) + len(maximum._bytes)
    if directory_bytes > 64 * 1024 * 1024:
        raise Error("B-tree directory byte limit exceeded")
    var writer = BinaryWriter()
    writer.write_u16(1)
    writer.write_u8(target)
    writer.write_u8(UInt8(string_getter_safe))
    _write_text(writer, column)
    _write_text(writer, path)
    writer.write_u32(UInt32(rows))
    writer.write_u32(UInt32(len(stats)))
    for i in range(len(stats)):
        writer.write_u32(UInt32(stats[i].row_count))
        writer.write_u32(UInt32(stats[i].null_count))
        writer.write_u32(UInt32(locations[i].offset))
        writer.write_u32(UInt32(locations[i].length))
        _write_key(writer, stats[i].minimum)
        _write_key(writer, stats[i].maximum)
    var prefix = writer.take_bytes()
    var payload_length = len(prefix) + length
    if payload_length > BTREE_MAX_BYTES:
        raise Error("B-tree payload byte limit exceeded")
    var output = create_anonymous_file()
    var sink = FileByteSink(output)
    var checked = CheckedByteSink(sink)
    var header = encode_cache_header(CACHE_JSON_BTREE_KIND, dimension, 0, sequence, source_checksum, payload_length)
    checked.write(Span(header))
    checked.write(Span(prefix))
    _ = file.seek(0)
    var offset = 0
    while offset < length:
        if control:
            control.value().checkpoint(0)
        var bytes = file.read_bytes(min(64 * 1024, length-offset))
        if len(bytes) == 0:
            raise Error("B-tree staged leaves are truncated")
        checked.write(Span(bytes))
        offset += len(bytes)
    write_checksum(sink, ~checked.register)
    var mapping = MappedFile.from_file(output)
    mapping.release_descriptor()
    var artifact = ArcPointer(MappedCacheArtifact(1, CACHE_JSON_BTREE_KIND, dimension, 0,
        sequence, source_checksum, payload_length, mapping^))
    return map_btree_pages(artifact, column, path, target, rows, control)
