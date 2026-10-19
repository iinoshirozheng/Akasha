"""ID-ordered compaction over pinned complete-state segment cursors."""

from akasha.document.point_codec import encode_point_record
from akasha.document.point_state import PointState
from akasha.document.vector_schema import FieldCatalog
from akasha.storage.byte_sink import (
    FileByteSink,
    CheckedByteSink,
    write_checksum,
)
from akasha.storage.filesystem import sync_file
from akasha.storage.manifest import Manifest
from akasha.storage.point_segment import (
    PointSegmentCursor,
    encode_point_segment_header,
)
from std.collections.binary_heap import BinaryHeap


@fieldwise_init
struct _Head(Comparable, TrivialRegisterPassable):
    var id: Int
    var run: Int

    # Reverse the max-heap ordering, without negating signed IDs (Int.MIN).
    # Equal IDs are consumed in manifest order so version checks are unchanged.
    def __lt__(self, other: Self) -> Bool:
        return self.id > other.id or (
            self.id == other.id and self.run > other.run
        )

    def __eq__(self, other: Self) -> Bool:
        return self.id == other.id and self.run == other.run

    def __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    def __gt__(self, other: Self) -> Bool:
        return other.__lt__(self)

    def __le__(self, other: Self) -> Bool:
        return not other.__lt__(self)

    def __ge__(self, other: Self) -> Bool:
        return not self.__lt__(other)


struct _Run[origin: ImmOrigin](Movable):
    var cursor: PointSegmentCursor[Self.origin]
    var head: Optional[PointState]

    def __init__(out self, var cursor: PointSegmentCursor[Self.origin]) raises:
        self.head = cursor.read_next()
        self.cursor = cursor^

    def rewind(mut self) raises:
        self.cursor.rewind()
        self.head = self.cursor.read_next()


struct PointMerge[origin: ImmOrigin](Movable):
    """Two passes over the same immutable mappings, with one head per input.

    Preflight validates every version, including overwritten/deleted records,
    and counts output records before an output file is claimed. The second pass
    emits unchanged canonical v5 records, without a table or whole output tape.
    """

    var _runs: List[_Run[Self.origin]]
    var _heap: BinaryHeap[_Head]
    var _catalog: Pointer[FieldCatalog, Self.origin]
    var _last_sequence: UInt64
    var _kind: Int
    var _minimum: UInt64
    var output_count: Int

    def __init__(
        out self,
        directory: String,
        manifest: Manifest,
        ref[Self.origin] catalog: FieldCatalog,
        *,
        first: Int = 0,
        limit: Int = -1,
    ) raises:
        var end = len(manifest.segments) if limit == -1 else limit
        if first < 0 or first >= end or end > len(manifest.segments):
            raise Error("invalid point compaction input range")
        catalog.validate()
        if (
            catalog.format_version != 2
            or catalog.field_at(0).dimension != manifest.dimension
            or manifest.last_sequence < catalog.legacy_cutover_sequence
        ):
            raise Error("point checkpoint catalog does not match manifest")
        self._runs = List[_Run[Self.origin]](capacity=end - first)
        self._heap = BinaryHeap[_Head](capacity=end - first)
        self._catalog = Pointer(to=catalog)
        self._last_sequence = manifest.segments[end - 1].max_sequence
        self._kind = 1 if first == 0 else 2
        self._minimum = UInt64(0) if first == 0 else manifest.segments[first].min_sequence
        self.output_count = 0
        for index in range(first, end):
            ref descriptor = manifest.segments[index]
            if (
                descriptor.sparse_name.byte_length() != 0
                or descriptor.sparse_checksum != 0
            ):
                raise Error(
                    "point checkpoints cannot carry legacy sparse segments"
                )
            var cursor = PointSegmentCursor(
                directory + "/" + descriptor.name, self._catalog[]
            )
            if (
                cursor.min_sequence != descriptor.min_sequence
                or cursor.last_sequence != descriptor.max_sequence
                or cursor.checksum != descriptor.checksum
                or (descriptor.level == 0 and cursor.kind != 2)
                or (descriptor.level > 0 and cursor.kind != 1)
            ):
                raise Error("point segment does not match committed manifest")
            self._runs.append(_Run(cursor^))
            self._offer(index - first)
        while True:
            var point = self._next_state()
            if not point:
                break
            if self.output_count == Int.MAX:
                raise Error(
                    "point compaction record count exceeds implementation limit"
                )
            self.output_count += 1
        self._rewind()

    def _offer(mut self, run: Int):
        if self._runs[run].head:
            self._heap.push(_Head(self._runs[run].head.value().id, run))

    def _rewind(mut self) raises:
        self._heap.clear()
        for index in range(len(self._runs)):
            self._runs[index].rewind()
            self._offer(index)

    def _next_state(mut self) raises -> Optional[PointState]:
        while len(self._heap) != 0:
            var item = self._heap.pop()
            var id = item.id
            var previous_sequence = UInt64(0)
            var latest: Optional[PointState]
            while True:
                var point = self._runs[item.run].head.take()
                if point.sequence <= previous_sequence:
                    raise Error("point checkpoint versions do not increase")
                if point.sequence > self._last_sequence:
                    raise Error(
                        "invalid checkpoint point sequence or duplicate ID"
                    )
                previous_sequence = point.sequence
                latest = Optional(point^)
                self._runs[item.run].head = self._runs[
                    item.run
                ].cursor.read_next()
                self._offer(item.run)
                if len(self._heap) == 0 or self._heap.peek().id != id:
                    break
                item = self._heap.pop()
            if self._kind == 2 or not latest.value().tombstone:
                return latest^
        return None

    def write_segment(mut self, path: String) raises -> UInt32:
        var header = encode_point_segment_header(
            self._kind, self._minimum, self._last_sequence, self.output_count, self._catalog[]
        )
        var checksum: UInt32
        with open(path, "w") as file:
            var sink = FileByteSink(file)
            # Point segment CRC starts at version, excluding four magic bytes.
            sink.write(Span(header)[:4])
            var checked = CheckedByteSink(sink)
            checked.write(Span(header)[4:])
            var emitted = 0
            while True:
                var point = self._next_state()
                if not point:
                    break
                var bytes = encode_point_record(point.value(), self._catalog[])
                checked.write(Span(bytes))
                emitted += 1
            if emitted != self.output_count:
                raise Error(
                    "point compaction count changed across immutable passes"
                )
            checksum = ~checked.register
            write_checksum(sink, checksum)
            sync_file(file)
        return checksum
