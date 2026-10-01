from akasha.document.point_state import (
    PointMutation,
    PointState,
    apply_point_mutation,
)
from akasha.document.vector_schema import FieldCatalog
from akasha.storage.filesystem import append_file_sync
from akasha.storage.memtable import MemTable, MemTableEntry
from akasha.storage.point_wal import (
    PointWalBatch,
    encode_point_batch,
    MAX_POINT_BATCH_MUTATIONS,
)
from std.collections import Dict
from std.memory import ArcPointer


@fieldwise_init
struct PointCommit(TrivialRegisterPassable):
    var first_sequence: UInt64
    var last_sequence: UInt64
    var mutation_count: Int


struct PointTable(Movable):
    """Latest complete point states behind a collection's writer exclusion.

    Preparation touches only mutated IDs and retains independent field owners.
    All raising validation and WAL encoding precede append/fsync. Publication
    uses only non-raising moves. An uncertain append poisons subsequent writes
    until the enclosing collection is reopened and its WAL is preflighted.
    """

    var _catalog: ArcPointer[FieldCatalog]
    var _points: List[PointState]
    var _ordinals: Dict[Int, Int]
    var _last_sequence: UInt64
    var _checkpoint_sequence: UInt64
    var _live_count: Int
    var _write_failed: Bool

    def __init__(
        out self,
        var catalog: ArcPointer[FieldCatalog],
        checkpoint_sequence: UInt64,
        var points: List[PointState] = List[PointState](),
    ) raises:
        catalog[].validate()
        if (
            catalog[].format_version != 2
            or checkpoint_sequence < catalog[].legacy_cutover_sequence
        ):
            raise Error(
                "point authority requires a catalog and valid checkpoint"
            )
        var ordinals = Dict[Int, Int]()
        var live_count = 0
        for ordinal in range(len(points)):
            ref point = points[ordinal]
            point.validate(catalog[])
            if point.sequence > checkpoint_sequence or point.id in ordinals:
                raise Error("invalid checkpoint point sequence or duplicate ID")
            ordinals[point.id] = ordinal
            if not point.tombstone:
                live_count += 1
        self._catalog = catalog^
        self._points = points^
        self._ordinals = ordinals^
        self._last_sequence = checkpoint_sequence
        self._checkpoint_sequence = checkpoint_sequence
        self._live_count = live_count
        self._write_failed = False

    def last_sequence(self) -> UInt64:
        return self._last_sequence

    def live_count(self) -> Int:
        return self._live_count

    def slot_count(self) -> Int:
        return len(self._points)

    def entry_view(self) -> Span[PointState, origin_of(self._points)]:
        return Span(self._points)

    def read_projection(self) raises -> MemTable:
        """Capture shared field descriptors in stable point-slot order."""
        var table = MemTable(self._catalog[].field_at(0).dimension)
        for index in range(len(self._points)):
            table.put(MemTableEntry.from_point(self._points[index]))
        table.last_sequence = self._last_sequence
        return table^

    def entry(
        self, id: Int
    ) raises -> ref[origin_of(self._points[0])] PointState:
        """Borrow the accepted state, including a tombstone, for publication."""
        var ordinal = self._ordinals.get(id, -1)
        if ordinal < 0:
            raise Error("accepted point is absent")
        return self._points[ordinal]

    def get(self, id: Int) -> Optional[PointState]:
        var ordinal = self._ordinals.get(id, -1)
        if ordinal < 0 or self._points[ordinal].tombstone:
            return Optional[PointState]()
        return Optional(self._points[ordinal].copy())

    def live_points(self) raises -> List[PointState]:
        """Capture ID-ordered descriptors for a complete-state base segment."""
        var ids = List[Int](capacity=self._live_count)
        for ordinal in range(len(self._points)):
            if not self._points[ordinal].tombstone:
                ids.append(self._points[ordinal].id)
        sort(Span(ids))
        var points = List[PointState](capacity=len(ids))
        for id in ids:
            points.append(self._points[self._ordinals[id]].copy())
        return points^

    def append_batch(
        mut self, wal_path: String, mutations: List[PointMutation]
    ) raises -> PointCommit:
        if self._write_failed:
            raise Error(
                "point writer requires recovery after failed WAL append"
            )
        if len(mutations) == 0 or len(mutations) > MAX_POINT_BATCH_MUTATIONS:
            raise Error("point batch count exceeds bounds")
        if UInt64(len(mutations)) > UInt64.MAX - self._last_sequence:
            raise Error("point sequence exhausted")
        var first = self._last_sequence + 1
        var last = self._last_sequence + UInt64(len(mutations))
        var states = self._prepare(first, mutations)
        var bytes = encode_point_batch(first, mutations, self._catalog[])
        self._points.reserve(len(self._points) + len(states))
        self._write_failed = True
        append_file_sync(wal_path, bytes)
        self._publish(states^, last)
        self._write_failed = False
        return PointCommit(first, last, len(mutations))

    def points_after(self, sequence: UInt64) raises -> List[PointState]:
        """Capture complete changed states, including tombstones, by point ID.
        """
        var ids = List[Int]()
        for ordinal in range(len(self._points)):
            if self._points[ordinal].sequence > sequence:
                ids.append(self._points[ordinal].id)
        sort(Span(ids))
        var points = List[PointState](capacity=len(ids))
        for id in ids:
            points.append(self._points[self._ordinals[id]].copy())
        return points^

    def replay(mut self, batch: PointWalBatch) raises:
        """Replay one complete, decoded envelope after full-source preflight.

        A checkpoint covers whole batches. A retained WAL prefix may be ignored,
        but a batch crossing the checkpoint or repeating newer state is corrupt.
        """
        if self._write_failed:
            raise Error("failed writer cannot be reused for recovery")
        var last = batch.last_sequence()
        if last <= self._checkpoint_sequence:
            return
        var states = self._prepare(batch.first_sequence, batch.mutations)
        self._publish(states^, last)

    def _prepare(
        self, first: UInt64, mutations: List[PointMutation]
    ) raises -> List[PointState]:
        if (
            len(mutations) == 0
            or len(mutations) > MAX_POINT_BATCH_MUTATIONS
            or first <= self._last_sequence
            or UInt64(len(mutations) - 1) > UInt64.MAX - first
        ):
            raise Error("invalid point batch sequence or count")
        var states = List[PointState]()
        var staged = Dict[Int, Int]()
        for index in range(len(mutations)):
            ref mutation = mutations[index]
            var staged_ordinal = staged.get(mutation.id, -1)
            var previous = Optional[PointState]()
            if staged_ordinal >= 0:
                previous = Optional(states[staged_ordinal].copy())
            else:
                var ordinal = self._ordinals.get(mutation.id, -1)
                if ordinal >= 0:
                    previous = Optional(self._points[ordinal].copy())
            var next = apply_point_mutation(
                previous, mutation, first + UInt64(index), self._catalog[]
            )
            if staged_ordinal >= 0:
                states[staged_ordinal] = next^
            else:
                staged[mutation.id] = len(states)
                states.append(next^)
        return states^

    def _publish(mut self, var states: List[PointState], last: UInt64):
        for var point in states^:
            var ordinal = self._ordinals.get(point.id, -1)
            if ordinal < 0:
                if not point.tombstone:
                    self._live_count += 1
                self._ordinals[point.id] = len(self._points)
                self._points.append(point^)
            else:
                if self._points[ordinal].tombstone != point.tombstone:
                    self._live_count += -1 if point.tombstone else 1
                self._points[ordinal] = point^
        self._last_sequence = last
