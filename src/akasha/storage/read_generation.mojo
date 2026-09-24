"""Immutable read owners, separate from mutable collection and snapshot handles.

A published root is a chain of immutable runs, oldest first: one base, up to
eight sealed deltas and at most one frozen head copy. Runs share dense owners
with the collection's MemTable. A row is visible only when it is live in its
run and no newer run holds any state (including a tombstone) for its ID.
"""

from akasha.common.config import CollectionConfig
from akasha.document.record import clone_fields, field_content_bytes
from akasha.index.bitmap import Bitmap
from akasha.index.metadata import MetadataIndex
from akasha.index.sparse import SparseIndex
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable
from std.memory import ArcPointer


comptime HEAD_MAX_POINTS = 1024
comptime HEAD_MAX_BYTES = 4 * 1024 * 1024
comptime MAX_SEALED_RUNS = 8


struct ReadRun(Movable):
    """One immutable run with a slot-aligned metadata index.

    Only construction mutates a run. Its dense rows are shared owners; its
    descriptors and payloads belong to this run alone.
    """

    var memtable: MemTable
    var metadata: MetadataIndex

    def __init__(out self, var memtable: MemTable, var metadata: MetadataIndex):
        self.memtable = memtable^
        self.metadata = metadata^


struct ReadLayer(Copyable, Movable):
    """A run as seen by one root: sorted slots shadowed by newer runs."""

    var run: ArcPointer[ReadRun]
    # Shared by every root with the same sealed chain; replaced, never mutated.
    var sealed_hidden: ArcPointer[List[Int]]
    # Slots shadowed by this root's frozen head; bounded by the head size.
    var head_hidden: List[Int]

    def __init__(
        out self,
        var run: ArcPointer[ReadRun],
        var sealed_hidden: ArcPointer[List[Int]],
        var head_hidden: List[Int],
    ):
        self.run = run^
        self.sealed_hidden = sealed_hidden^
        self.head_hidden = head_hidden^

    def is_shadowed(self) -> Bool:
        return len(self.sealed_hidden[]) > 0 or len(self.head_hidden) > 0

    def visible(self, ordinals: List[Int]) raises -> List[Int]:
        """Drop tombstones and shadowed slots from ascending run slots."""
        var result = List[Int](capacity=len(ordinals))
        var sealed = 0
        var head = 0
        for ordinal in ordinals:
            if not self.run[].memtable.is_live_at(ordinal):
                continue
            while (
                sealed < len(self.sealed_hidden[])
                and self.sealed_hidden[][sealed] < ordinal
            ):
                sealed += 1
            while head < len(self.head_hidden) and self.head_hidden[head] < ordinal:
                head += 1
            if (
                sealed < len(self.sealed_hidden[])
                and self.sealed_hidden[][sealed] == ordinal
            ) or (head < len(self.head_hidden) and self.head_hidden[head] == ordinal):
                continue
            result.append(ordinal)
        return result^


struct ReadGeneration(Movable):
    """One published view; its last strong owner releases its generation pin."""

    var config: CollectionConfig
    var generation: UInt64
    var sequence: UInt64
    var revision: UInt64
    var layers: List[ReadLayer]
    var sparse: ArcPointer[SparseIndex]
    var visible_count: Int
    var _pins: ArcPointer[GenerationPinRegistry]

    def __init__(
        out self,
        config: CollectionConfig,
        generation: UInt64,
        sequence: UInt64,
        revision: UInt64,
        var layers: List[ReadLayer],
        var sparse: ArcPointer[SparseIndex],
        visible_count: Int,
        var pins: ArcPointer[GenerationPinRegistry],
    ):
        self.config = config.copy()
        self.generation = generation
        self.sequence = sequence
        self.revision = revision
        self.layers = layers^
        self.sparse = sparse^
        self.visible_count = visible_count
        self._pins = pins^
        self._pins[].pin(generation)

    def __deinit__(deinit self):
        self._pins[].unpin(self.generation)

    def layer_count(self) -> Int:
        return len(self.layers)

    def run(self, layer: Int) -> ref[origin_of(self.layers[layer].run[], self)] ReadRun:
        """Borrow one run readonly; union with self blocks mutation."""
        return self.layers[layer].run[]

    def find(self, id: Int) raises -> Tuple[Int, Int]:
        """Return (layer, slot) of the newest live state, or (-1, -1)."""
        var layer = len(self.layers) - 1
        while layer >= 0:
            ref table = self.layers[layer].run[].memtable
            var ordinal = table.ordinal_for(id)
            if ordinal >= 0:
                if not table.is_live_at(ordinal):
                    return (-1, -1)
                return (layer, ordinal)
            layer -= 1
        return (-1, -1)

    def visible_ordinals(self, layer: Int) raises -> List[Int]:
        """Return ascending visible slots of one run."""
        ref item = self.layers[layer]
        if not item.is_shadowed():
            return item.run[].memtable.live_ordinals()
        return item.visible(item.run[].memtable.live_ordinals())

    def candidate_ordinals(self, layer: Int, candidates: Bitmap) raises -> List[Int]:
        """Return visible slots of one run selected by its own metadata bitmap."""
        ref item = self.layers[layer]
        if candidates.size() != item.run[].memtable.slot_count():
            raise Error("candidate bitmap does not align with run slots")
        var selected = List[Int](capacity=candidates.count())
        for ordinal in candidates.set_ordinals():
            selected.append(ordinal)
        return item.visible(selected)

    def id_ordered_locations(self) raises -> List[Tuple[Int, Int]]:
        """Return (layer, slot) of every visible row in ascending ID order."""
        var ids = List[Int](capacity=self.visible_count)
        for layer in range(len(self.layers)):
            for ordinal in self.visible_ordinals(layer):
                ids.append(self.layers[layer].run[].memtable.id_at(ordinal))
        sort(Span(ids))
        var locations = List[Tuple[Int, Int]](capacity=len(ids))
        for id in ids:
            locations.append(self.find(id))
        return locations^

    def dense_run(self) raises -> ArcPointer[ReadRun]:
        """Return one run holding exactly the visible rows, for device upload.

        An unshadowed single run is shared. Otherwise this builds a flat table
        of descriptors that share dense owners and omit payload.
        """
        if len(self.layers) == 1 and not self.layers[0].is_shadowed():
            return self.layers[0].run.copy()
        var table = MemTable(self.config.dimension)
        for layer in range(len(self.layers)):
            ref source = self.layers[layer].run[].memtable
            for ordinal in self.visible_ordinals(layer):
                table.put(source.entry_ref_at(ordinal).dense_descriptor())
        table.last_sequence = self.sequence
        return ArcPointer(ReadRun(table^, MetadataIndex()))


struct ReadPublisherStats(Copyable, Movable):
    """Cumulative publisher work; dense bytes are audited by owner identity."""

    var base_builds: Int
    var rollovers: Int
    var consolidations: Int
    var head_freezes: Int
    var descriptor_copies: Int
    var payload_bytes: Int
    var sparse_bytes: Int

    def __init__(out self):
        self.base_builds = 0
        self.rollovers = 0
        self.consolidations = 0
        self.head_freezes = 0
        self.descriptor_copies = 0
        self.payload_bytes = 0
        self.sparse_bytes = 0


struct ReadGenerationCache(Movable):
    """Collection-local publisher, accessed only under the collection writer lock.

    It owns the base and sealed runs, the bounded mutable head and the cached
    root. Each committed dense write is recorded into the head; capture freezes
    a copy of only the head. Existing read handles keep old roots alive.
    """

    var root: Optional[ArcPointer[ReadGeneration]]
    var revision: UInt64
    var stats: ReadPublisherStats
    var _layers: List[ReadLayer]
    var _head: Optional[MemTable]
    var _head_bytes: Int
    var _frozen_head: Optional[ArcPointer[ReadRun]]
    var _sparse: Optional[ArcPointer[SparseIndex]]
    var _dense_sequence: UInt64

    def __init__(out self):
        self.root = Optional[ArcPointer[ReadGeneration]]()
        self.revision = 0
        self.stats = ReadPublisherStats()
        self._layers = List[ReadLayer]()
        self._head = Optional[MemTable]()
        self._head_bytes = 0
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        self._sparse = Optional[ArcPointer[SparseIndex]]()
        self._dense_sequence = 0

    def invalidate(mut self):
        """Drop the cached root after a publication; runs stay valid."""
        self.root = Optional[ArcPointer[ReadGeneration]]()

    def reset(mut self):
        """Drop all derived state; the next capture builds a new base."""
        self.invalidate()
        self._layers = List[ReadLayer]()
        self._head = Optional[MemTable]()
        self._head_bytes = 0
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        self._sparse = Optional[ArcPointer[SparseIndex]]()

    def sealed_count(self) -> Int:
        return max(0, len(self._layers) - 1)

    def head_count(self) -> Int:
        return self._head.value().slot_count() if self._head else 0

    def record_sparse(mut self):
        """A sparse write replaces only the sparse owner at the next capture."""
        self.invalidate()
        self._sparse = Optional[ArcPointer[SparseIndex]]()

    def record(mut self, memtable: MemTable, ids: List[Int]):
        """Record committed latest states for IDs, after WAL and MemTable apply.

        Rollover and foreground consolidation happen here. A failure after the
        commit cannot reject the write, so it drops derived state instead.
        """
        self.invalidate()
        if len(self._layers) == 0:
            return
        try:
            for id in ids:
                self._record_one(memtable, id)
            self._dense_sequence = memtable.last_sequence
        except:
            self.reset()

    def consolidate(mut self, memtable: MemTable) raises:
        """Merge the chain into a new base from the writer's latest state.

        Foreground in #48: the caller holds the writer lock for its duration.
        Dense owners are shared; descriptors, payload and metadata are rebuilt.
        """
        if len(self._layers) == 0:
            return
        self.invalidate()
        self._layers = List[ReadLayer]()
        self._head = Optional[MemTable]()
        self._head_bytes = 0
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        self._build_base(memtable)
        self.stats.consolidations += 1

    def acquire(
        mut self,
        config: CollectionConfig,
        generation: UInt64,
        sequence: UInt64,
        memtable: MemTable,
        sparse: SparseIndex,
        pins: ArcPointer[GenerationPinRegistry],
    ) raises -> ArcPointer[ReadGeneration]:
        if self.root:
            ref current = self.root.value()[]
            if (
                current.generation == generation
                and current.sequence == sequence
                and current.config.fingerprint() == config.fingerprint()
            ):
                return self.root.value()
        if self.revision == UInt64.MAX:
            raise Error("read view revision exhausted")
        config.validate()
        if memtable.dimension != config.dimension:
            raise Error("snapshot dimension mismatch")
        if memtable.last_sequence > sequence:
            raise Error("snapshot sequence precedes memtable")
        if len(self._layers) == 0:
            self._build_base(memtable)
        elif self._dense_sequence != memtable.last_sequence:
            raise Error("read publisher missed a committed dense write")
        if not self._sparse:
            self._sparse = Optional(ArcPointer(sparse.clone()))
            self.stats.sparse_bytes += sparse.content_bytes()
        var layers = List[ReadLayer](capacity=len(self._layers) + 1)
        for layer in self._layers:
            layers.append(layer.copy())
        if self.head_count() > 0:
            if not self._frozen_head:
                self._frozen_head = Optional(
                    ArcPointer(_frozen_run(self._head.value(), self.stats))
                )
                self.stats.head_freezes += 1
            var frozen = self._frozen_head.value()
            ref head = frozen[].memtable
            for layer in range(len(layers)):
                ref table = layers[layer].run[].memtable
                for slot in range(head.slot_count()):
                    var ordinal = table.ordinal_for(head.id_at(slot))
                    if ordinal >= 0:
                        layers[layer].head_hidden.append(ordinal)
                sort(Span(layers[layer].head_hidden))
            layers.append(
                ReadLayer(frozen^, ArcPointer(List[Int]()), List[Int]())
            )
        # The layered view resolves to exactly the writer's committed state.
        var visible = memtable.live_count()
        var root = ArcPointer(
            ReadGeneration(
                config,
                generation,
                sequence,
                self.revision + 1,
                layers^,
                self._sparse.value(),
                visible,
                pins,
            )
        )
        self.root = Optional(root)
        self.revision += 1
        return root^

    def _build_base(mut self, memtable: MemTable) raises:
        var run = _frozen_run(memtable, self.stats)
        self._layers = List[ReadLayer]()
        self._layers.append(
            ReadLayer(ArcPointer(run^), ArcPointer(List[Int]()), List[Int]())
        )
        self._head = Optional(MemTable(memtable.dimension))
        self._head_bytes = 0
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        self._dense_sequence = memtable.last_sequence
        self.stats.base_builds += 1

    def _record_one(mut self, memtable: MemTable, id: Int) raises:
        var ordinal = memtable.ordinal_for(id)
        if ordinal < 0:
            raise Error("recorded ID is absent from the writer table")
        ref entry = memtable.entry_ref_at(ordinal)
        var incoming = entry.dense_bytes() + field_content_bytes(entry.fields)
        var replaced = 0
        var existing = self._head.value().ordinal_for(id)
        if existing >= 0:
            ref previous = self._head.value().entry_ref_at(existing)
            replaced = previous.dense_bytes() + field_content_bytes(
                previous.fields
            )
        var others = self.head_count() - (1 if existing >= 0 else 0)
        # A record that would overflow a non-empty head starts a new one, so a
        # legal oversized record gets its own run instead of a rejection.
        if others > 0 and self._head_bytes - replaced + incoming > HEAD_MAX_BYTES:
            self._seal()
            replaced = 0
        # The frozen copy belongs to published roots; the next capture needs
        # a new one. The mutable head is never shared.
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        self._head.value().put(entry.clone())
        self._head_bytes += incoming - replaced
        self.stats.descriptor_copies += 1
        self.stats.payload_bytes += field_content_bytes(entry.fields)
        if (
            self.head_count() >= HEAD_MAX_POINTS
            or self._head_bytes >= HEAD_MAX_BYTES
        ):
            self._seal()
        if self.sealed_count() >= MAX_SEALED_RUNS:
            # The writer table already holds the whole accepted envelope, so
            # later IDs of the same batch only re-record identical states.
            self.consolidate(memtable)

    def _seal(mut self) raises:
        """Move the head into a sealed run; only its metadata is built."""
        var table = self._head.take()
        self._head = Optional(MemTable(table.dimension))
        self._head_bytes = 0
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        var metadata = _build_metadata(table, self.stats)
        var run = ArcPointer(ReadRun(table^, metadata^))
        ref sealed = run[].memtable
        for layer in range(len(self._layers)):
            ref older = self._layers[layer].run[].memtable
            var added = List[Int]()
            for slot in range(sealed.slot_count()):
                var ordinal = older.ordinal_for(sealed.id_at(slot))
                if ordinal >= 0:
                    added.append(ordinal)
            if len(added) == 0:
                continue
            var merged = self._layers[layer].sealed_hidden[].copy()
            merged.extend(added^)
            sort(Span(merged))
            var unique = List[Int](capacity=len(merged))
            for ordinal in merged:
                if len(unique) == 0 or unique[len(unique) - 1] != ordinal:
                    unique.append(ordinal)
            # Replace the shared list; roots already published keep the old one.
            self._layers[layer].sealed_hidden = ArcPointer(unique^)
        self._layers.append(ReadLayer(run^, ArcPointer(List[Int]()), List[Int]()))
        self.stats.rollovers += 1


def _frozen_run(source: MemTable, mut stats: ReadPublisherStats) raises -> ReadRun:
    """Copy descriptors and payload, share dense owners, index metadata."""
    var table = source.clone()
    stats.descriptor_copies += table.slot_count()
    for slot in range(table.slot_count()):
        stats.payload_bytes += field_content_bytes(
            table.entry_ref_at(slot).fields
        )
    var metadata = _build_metadata(table, stats)
    return ReadRun(table^, metadata^)


def _build_metadata(
    table: MemTable, mut stats: ReadPublisherStats
) raises -> MetadataIndex:
    var index = MetadataIndex()
    index.begin_bulk()
    for ordinal in range(table.slot_count()):
        ref entry = table.entry_ref_at(ordinal)
        if entry.tombstone:
            index.delete(entry.id)
        else:
            stats.payload_bytes += field_content_bytes(entry.fields)
            var fields = clone_fields(entry.fields)
            index.upsert(entry.id, fields^)
    index.finish_bulk()
    if index.slot_count() != table.slot_count():
        raise Error("snapshot metadata slot alignment failed")
    return index^
