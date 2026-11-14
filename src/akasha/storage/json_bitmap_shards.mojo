"""Validated local-ordinal shards, streaming k-way merge and atomic publication.

Lance bitmap.rs merge_shards/drain_same_key_bitmaps (Apache-2.0) supplies the
heap/cursor/union algorithm. Akasha uses its own v1 payload and AKIC envelope.
"""
from std.memory import ArcPointer
from std.collections.binary_heap import BinaryHeap
from std.sys import size_of
from akasha.storage.checksum import BinaryWriter
from akasha.storage.byte_sink import ByteSink, FileByteSink, CheckedByteSink, drain_bytes, write_checksum
from akasha.storage.filesystem import create_anonymous_file
from akasha.storage.mapped_file import MappedFile
from akasha.storage.mapped_reader import MappedBinaryReader
from akasha.storage.index_cache import MappedCacheArtifact, CACHE_JSON_BITMAP_KIND, encode_cache_header
from akasha.storage.json_bitmap_codec import _read_text, _write_text, _read_bitmap_key, _write_bitmap_key, map_shared_json_bitmap
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.roaring_rows import RoaringRowSet
from akasha.query.control import QueryControl


comptime JSON_SHARD_ROWS = 4096
comptime JSON_MAX_SHARDS = 245


def shard_name(full_name: String, slot: Int) -> String:
    return full_name + ".shard-" + String(slot)


def _payload_header(column: String, path: String, target: UInt8, safe: Bool,
                    keys: Int, rows: Int) -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_u16(1)
    writer.write_u8(target)
    writer.write_u8(UInt8(safe))
    _write_text(writer, column)
    _write_text(writer, path)
    writer.write_u32(UInt32(keys))
    writer.write_u32(UInt32(rows))
    return writer.take_bytes()


def _key_bytes(key: LanceScalarKey) -> Int:
    return 0 if key.is_null else 8 if key.target <= 3 else 4 + len(key._bytes)


def _write_posting(mut sink: Some[ByteSink], key: LanceScalarKey, rows: RoaringRowSet,
                   control: Optional[QueryControl]) raises:
    var writer = BinaryWriter()
    if not key.is_null:
        _write_bitmap_key(writer, key)
    writer.write_u32(UInt32(rows.count()))
    drain_bytes(writer, sink)
    var ordinal = 0
    for id in rows.values(control=control.copy()):
        if control:
            control.value().checkpoint(ordinal)
        writer.write_u64(id)
        ordinal += 1
        if ordinal % 4096 == 0:
            drain_bytes(writer, sink)
    drain_bytes(writer, sink)


def stage_json_bitmap(column: String, index: LanceJsonBitmapIndex, dimension: Int,
                      generation: UInt64, sequence: UInt64, checksum: UInt32,
                      control: Optional[QueryControl] = None) raises -> ArcPointer[MappedCacheArtifact]:
    var prefix = _payload_header(column, index.path, index.target(), index._string_getter_safe,
        len(index._bitmap._keys), index._bitmap._rows)
    var length = len(prefix) + 4 * (len(index._bitmap._keys) + 1) + 8 * index._bitmap._rows
    for key in index._bitmap._keys:
        length += _key_bytes(key)
    if length > 128 * 1024 * 1024:
        raise Error("JSON bitmap cache payload byte limit exceeded")
    var file = create_anonymous_file()
    var sink = FileByteSink(file)
    var checked = CheckedByteSink(sink)
    var header = encode_cache_header(CACHE_JSON_BITMAP_KIND, dimension, generation, sequence, checksum, length)
    checked.write(Span(header))
    checked.write(Span(prefix))
    _write_posting(checked, LanceScalarKey.null(index.target()), index._bitmap.null_rows(control), control)
    for i in range(len(index._bitmap._keys)):
        _write_posting(checked, index._bitmap._keys[i], index._bitmap.posting(i, control), control)
    if checked.byte_length != UInt64(36 + length):
        raise Error("JSON bitmap staged length mismatch")
    write_checksum(sink, ~checked.register)
    var mapping = MappedFile.from_file(file)
    mapping.release_descriptor()
    return ArcPointer(MappedCacheArtifact(1, CACHE_JSON_BITMAP_KIND, dimension, generation,
        sequence, checksum, length, mapping^))


struct _ShardCursor(Movable):
    var artifact: ArcPointer[MappedCacheArtifact]
    var base: Int
    var rows: Int
    var keys: Int
    var slot: Int
    var offset: Int
    var posting: Int
    var count: Int
    var key: LanceScalarKey
    var safe: Bool

    def __init__(out self, artifact: ArcPointer[MappedCacheArtifact], base: Int,
                 column: String, path: String, target: UInt8,
                 control: Optional[QueryControl]) raises:
        self.artifact = artifact.copy()
        self.base = base
        var reader = artifact[].payload_reader()
        if reader.read_u16() != 1 or reader.read_u8() != target:
            raise Error("JSON shard type/version mismatch")
        self.safe = reader.read_u8() == 1
        if _read_text(reader) != column or _read_text(reader) != path:
            raise Error("JSON shard definition mismatch")
        self.keys = Int(reader.read_u32())
        self.rows = Int(reader.read_u32())
        if self.rows > JSON_SHARD_ROWS:
            raise Error("JSON shard row limit exceeded")
        # Validate all keys/coverage before any output can be published; retain
        # only this cursor's head rather than every shard's key directory.
        _ = map_shared_json_bitmap(artifact, column, path, target, self.rows, control,
            cache_bytes=0, cache_entries=0)
        self.slot = 0
        self.key = LanceScalarKey.null(target)
        self.count = Int(reader.read_u32())
        self.posting = 36 + reader.position()
        self.offset = self.posting + self.count * 8

    def advance(mut self) raises -> Bool:
        if self.slot == self.keys:
            return False
        self.slot += 1
        var reader = MappedBinaryReader(Pointer(to=self.artifact[]._mapping), self.offset,
            36 + self.artifact[].payload_length - self.offset)
        self.key = _read_bitmap_key(reader, self.key.target)
        self.count = Int(reader.read_u32())
        self.posting = self.offset + reader.position()
        self.offset = self.posting + self.count * 8
        return True

    def load(self, control: Optional[QueryControl]) raises -> RoaringRowSet:
        var rows = RoaringRowSet()
        for i in range(self.count):
            if control:
                control.value().checkpoint(i)
            var id = self.artifact[]._mapping.load_scalars[DType.uint64, 1](self.posting + i * 8)
            _ = rows.insert(id + UInt64(self.base))
        return rows^


@fieldwise_init
struct _Head(Comparable, Copyable, Movable):
    var key: LanceScalarKey
    var shard: Int

    def __lt__(self, other: Self) -> Bool:
        var compare = self.key._compare_same(other.key)
        return compare > 0 or (compare == 0 and self.shard > other.shard)
    def __eq__(self, other: Self) -> Bool:
        return self.key._compare_same(other.key) == 0 and self.shard == other.shard
    def __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)
    def __gt__(self, other: Self) -> Bool:
        return other.__lt__(self)
    def __le__(self, other: Self) -> Bool:
        return not other.__lt__(self)
    def __ge__(self, other: Self) -> Bool:
        return not self.__lt__(other)


struct _Merge(Movable):
    var cursors: List[_ShardCursor]
    var heap: BinaryHeap[_Head]
    var rows: Int
    var safe: Bool
    var head_bytes: Int
    var control: Optional[QueryControl]

    def __init__(out self, shards: List[ArcPointer[MappedCacheArtifact]], column: String,
                 path: String, target: UInt8, control: Optional[QueryControl]) raises:
        if len(shards) == 0 or len(shards) > JSON_MAX_SHARDS:
            raise Error("invalid JSON bitmap shard count")
        self.cursors = List[_ShardCursor]()
        self.heap = BinaryHeap[_Head]()
        self.rows = 0
        self.safe = True
        self.head_bytes = 0
        self.control = control.copy()
        for shard in shards:
            if control:
                control.value().checkpoint(0)
            self.cursors.append(_ShardCursor(shard, self.rows, column, path, target, control))
            self.rows += self.cursors[len(self.cursors)-1].rows
            if self.rows > 1_000_000:
                raise Error("JSON bitmap merged row limit exceeded")
            self.safe = self.safe and self.cursors[len(self.cursors)-1].safe
            self._offer(len(self.cursors)-1)
        if control:
            control.value().validate_candidate_count(self.rows)

    def _offer(mut self, shard: Int) raises:
        self.head_bytes += 2 * len(self.cursors[shard].key._bytes) + size_of[_Head]()
        if self.head_bytes > 64 * 1024 * 1024:
            raise Error("JSON bitmap shard head byte limit exceeded")
        self.heap.push(_Head(self.cursors[shard].key.copy(), shard))

    def next(mut self) raises -> Optional[Tuple[LanceScalarKey, RoaringRowSet]]:
        if len(self.heap) == 0:
            return None
        var item = self.heap.pop()
        var key = item.key.copy()
        var rows = RoaringRowSet()
        while True:
            if self.control:
                self.control.value().checkpoint(0)
            self.head_bytes -= 2 * len(item.key._bytes) + size_of[_Head]()
            rows = rows.union_with(self.cursors[item.shard].load(self.control), control=self.control.copy())
            if self.cursors[item.shard].advance():
                self._offer(item.shard)
            else:
                self.cursors[item.shard].key = LanceScalarKey.null(key.target)
            if len(self.heap) == 0 or self.heap.peek().key._compare_same(key) != 0:
                break
            item = self.heap.pop()
        return Optional((key^, rows^))


def merge_json_bitmap_shards(shards: List[ArcPointer[MappedCacheArtifact]], column: String,
                              path: String, target: UInt8, dimension: Int,
                              sequence: UInt64, checksum: UInt32,
                              control: Optional[QueryControl] = None) raises -> LanceJsonBitmapIndex:
    var staging_bytes = 0
    for shard in shards:
        if shard[].dimension != dimension or shard[].kind != CACHE_JSON_BITMAP_KIND:
            raise Error("JSON bitmap shard envelope mismatch")
        staging_bytes += shard[]._mapping.byte_length()
        if staging_bytes > 512 * 1024 * 1024:
            raise Error("JSON bitmap shard staging byte limit exceeded")
    var merge = _Merge(shards, column, path, target, control)
    var keys = 0
    var length = 0
    var logical_bytes = 0
    while True:
        var entry = merge.next()
        if not entry:
            break
        ref key = entry.value()[0]
        ref rows = entry.value()[1]
        length += _key_bytes(key) + 4 + rows.count() * 8
        logical_bytes += rows._bytes
        if not key.is_null:
            keys += 1
            logical_bytes += size_of[LanceScalarKey]() + size_of[RoaringRowSet]() + len(key._bytes)
        if logical_bytes > 64 * 1024 * 1024 or length > 128 * 1024 * 1024:
            raise Error("JSON merged bitmap byte limit exceeded")
    var prefix = _payload_header(column, path, target, merge.safe, keys, merge.rows)
    length += len(prefix)
    if length > 128 * 1024 * 1024:
        raise Error("JSON merged bitmap payload byte limit exceeded")
    if staging_bytes + length + 40 > 512 * 1024 * 1024:
        raise Error("JSON bitmap merged staging byte limit exceeded")
    var row_count = merge.rows
    var file = create_anonymous_file()
    var sink = FileByteSink(file)
    var checked = CheckedByteSink(sink)
    var header = encode_cache_header(CACHE_JSON_BITMAP_KIND, dimension, 0, sequence, checksum, length)
    checked.write(Span(header))
    checked.write(Span(prefix))
    merge = _Merge(shards, column, path, target, control)
    while True:
        var entry = merge.next()
        if not entry:
            break
        _write_posting(checked, entry.value()[0], entry.value()[1], control)
    if checked.byte_length != UInt64(36 + length):
        raise Error("JSON merged bitmap length changed")
    write_checksum(sink, ~checked.register)
    var mapping = MappedFile.from_file(file)
    mapping.release_descriptor()
    var artifact = ArcPointer(MappedCacheArtifact(1, CACHE_JSON_BITMAP_KIND, dimension, 0,
        sequence, checksum, length, mapping^))
    var result = map_shared_json_bitmap(artifact, column, path, target, row_count, control)
    result._bitmap._shards = shards.copy()
    return result^
