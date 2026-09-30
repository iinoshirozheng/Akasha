"""Immutable read owners, separate from mutable collection and snapshot handles.

A published root is a chain of immutable runs, oldest first: one base, sealed
deltas and at most one frozen head copy. From the eighth sealed run a merge of
the run prefix into a new base is due; writers wait at sixteen. Runs share dense, payload
and sparse field owners with the collection's MemTable. A row is visible only
when it is live in its run and no newer run holds any state (including a
tombstone) for its ID. Base and sealed runs carry metadata and sparse indexes
over their own slots; the small frozen head is evaluated directly.
"""

from akasha.common.config import CollectionConfig
from akasha.compute.gpu.context import GpuSnapshotState
from akasha.document.record import clone_fields
from akasha.index.artifact_state import ArtifactState, PqArtifacts
from akasha.index.bitmap import Bitmap
from akasha.index.metadata import MetadataIndex
from akasha.index.quantization import Sq8Index
from akasha.index.sparse import SparseElement, SparseIndex
from akasha.query.evaluator import matches_all, matches_expression
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.index_evaluator import evaluate_all, evaluate_expression
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable, MemTableEntry
from std.memory import ArcPointer
from std.time import sleep


comptime HEAD_MAX_POINTS = 1024
comptime HEAD_MAX_BYTES = 4 * 1024 * 1024
comptime MAX_SEALED_RUNS = 8
"""Sealed runs at which a merge of the run prefix is due."""
comptime SEALED_RUN_LIMIT = 2 * MAX_SEALED_RUNS
"""Sealed runs at which writers wait for the merge before the next write."""


struct RunIndex(Movable):
    """Derived indexes of one run: metadata by slot, sparse by live ID."""

    var metadata: MetadataIndex
    var sparse: SparseIndex

    def __init__(
        out self, var metadata: MetadataIndex, var sparse: SparseIndex
    ):
        self.metadata = metadata^
        self.sparse = sparse^


struct SparseHit(TrivialRegisterPassable):
    """A visible row's sparse dot product, located in its run."""

    var ordinal: Int
    var id: Int
    var score: Float32

    def __init__(out self, ordinal: Int, id: Int, score: Float32):
        self.ordinal = ordinal
        self.id = id
        self.score = score


struct ReadRun(Movable):
    """One immutable run; only construction mutates it.

    Field owners are shared; its descriptors belong to this run alone. A run
    without an index (the frozen head) is evaluated field by field.
    """

    var memtable: MemTable
    var index: Optional[RunIndex]

    def __init__(
        out self, var memtable: MemTable, var index: Optional[RunIndex]
    ):
        self.memtable = memtable^
        self.index = index^


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

    def is_visible(self, ordinal: Int) raises -> Bool:
        """Check one slot: live in its run and not shadowed by a newer run."""
        return (
            self.run[].memtable.is_live_at(ordinal)
            and not contains_sorted(self.sealed_hidden[], ordinal)
            and not contains_sorted(self.head_hidden, ordinal)
        )

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
            while (
                head < len(self.head_hidden)
                and self.head_hidden[head] < ordinal
            ):
                head += 1
            if (
                sealed < len(self.sealed_hidden[])
                and self.sealed_hidden[][sealed] == ordinal
            ) or (
                head < len(self.head_hidden)
                and self.head_hidden[head] == ordinal
            ):
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
    var visible_count: Int
    # Device table and cache derived from this root; shared by every handle
    # and operation that owns the root, released with it.
    var device: ArcPointer[GpuSnapshotState]
    # SQ8 artifact derived from this root; shared by every handle and
    # operation that owns the root, built once and released with it.
    var sq8: ArcPointer[ArtifactState[Sq8Index]]
    var pq: ArcPointer[PqArtifacts]
    var _pins: ArcPointer[GenerationPinRegistry]

    def __init__(
        out self,
        config: CollectionConfig,
        generation: UInt64,
        sequence: UInt64,
        revision: UInt64,
        var layers: List[ReadLayer],
        visible_count: Int,
        var pins: ArcPointer[GenerationPinRegistry],
    ):
        self.config = config.copy()
        self.generation = generation
        self.sequence = sequence
        self.revision = revision
        self.layers = layers^
        self.visible_count = visible_count
        self.device = ArcPointer(GpuSnapshotState(generation, sequence))
        self.sq8 = ArcPointer(ArtifactState[Sq8Index]())
        self.pq = ArcPointer(PqArtifacts())
        self._pins = pins^
        self._pins[].pin(generation)

    def __deinit__(deinit self):
        self._pins[].unpin(self.generation)

    def layer_count(self) -> Int:
        return len(self.layers)

    def run(
        self, layer: Int
    ) -> ref[origin_of(self.layers[layer].run[], self)] ReadRun:
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

    def candidate_ordinals(
        self, layer: Int, candidates: Bitmap
    ) raises -> List[Int]:
        """Return visible slots of one run selected by its own metadata bitmap.
        """
        ref item = self.layers[layer]
        if candidates.size() != item.run[].memtable.slot_count():
            raise Error("candidate bitmap does not align with run slots")
        var selected = List[Int](capacity=candidates.count())
        for ordinal in candidates.set_ordinals():
            selected.append(ordinal)
        return item.visible(selected)

    def filtered_ordinals(
        self, layer: Int, expression: FilterExpression
    ) raises -> List[Int]:
        """Return ascending visible slots of one run matching a filter."""
        ref run = self.layers[layer].run[]
        if run.index:
            return self.candidate_ordinals(
                layer,
                evaluate_expression(run.index.value().metadata, expression),
            )
        var result = List[Int]()
        for ordinal in self.visible_ordinals(layer):
            if matches_expression(
                run.memtable.entry_ref_at(ordinal).fields(), expression
            ):
                result.append(ordinal)
        return result^

    def conditioned_ordinals(
        self, layer: Int, conditions: List[FilterCondition]
    ) raises -> List[Int]:
        """Return ascending visible slots of one run matching every condition.
        """
        ref run = self.layers[layer].run[]
        if run.index:
            return self.candidate_ordinals(
                layer, evaluate_all(run.index.value().metadata, conditions)
            )
        var result = List[Int]()
        for ordinal in self.visible_ordinals(layer):
            if matches_all(
                run.memtable.entry_ref_at(ordinal).fields(), conditions
            ):
                result.append(ordinal)
        return result^

    def sparse_hits(
        self, layer: Int, query: List[SparseElement]
    ) raises -> List[SparseHit]:
        """Score visible rows of one run sharing a term with a valid query.

        Indexed and direct scoring both sum in ascending query-term order, so
        a row scores bit-identically in any run.
        """
        ref item = self.layers[layer]
        ref table = item.run[].memtable
        var hits = List[SparseHit]()
        if item.run[].index:
            for scored in item.run[].index.value().sparse.scores(query):
                var ordinal = table.ordinal_for(scored.id)
                if ordinal >= 0 and item.is_visible(ordinal):
                    hits.append(SparseHit(ordinal, scored.id, scored.score))
            return hits^
        for ordinal in self.visible_ordinals(layer):
            ref entry = table.entry_ref_at(ordinal)
            if not entry.has_sparse():
                continue
            var score = _sparse_dot(query, entry.sparse())
            if score:
                hits.append(SparseHit(ordinal, entry.id, score.value()))
        return hits^

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
        return ArcPointer(ReadRun(table^, Optional[RunIndex]()))


struct ReadPublisherStats(Copyable, Movable):
    """Cumulative publisher work; field owners are audited by identity.

    Payload and sparse bytes count only copies into derived run indexes.
    """

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


struct SealedMerge(Movable):
    """A captured run prefix and the base merged from it.

    Capture and publish run under the writer lock; `build` does not. Runs are
    immutable once sealed, so the build reads them while writers continue.
    """

    var runs: List[ArcPointer[ReadRun]]
    """The base and sealed runs at capture, oldest first."""
    var base: Optional[ArcPointer[ReadRun]]
    var stats: ReadPublisherStats
    var delay_for_test: Float64
    var fail_for_test: Bool

    def __init__(
        out self,
        var runs: List[ArcPointer[ReadRun]],
        delay_for_test: Float64,
        fail_for_test: Bool,
    ):
        self.runs = runs^
        self.base = Optional[ArcPointer[ReadRun]]()
        self.stats = ReadPublisherStats()
        self.delay_for_test = delay_for_test
        self.fail_for_test = fail_for_test

    def build(mut self) raises:
        """Fold the runs, newest state winning, into one indexed base."""
        if self.delay_for_test > 0:
            sleep(self.delay_for_test)
        if self.fail_for_test:
            raise Error("sealed run merge failed for test")
        var table = self.runs[0][].memtable.clone()
        self.stats.descriptor_copies += table.slot_count()
        for index in range(1, len(self.runs)):
            ref source = self.runs[index][].memtable
            for slot in range(source.slot_count()):
                table.put(source.entry_ref_at(slot).clone())
            self.stats.descriptor_copies += source.slot_count()
        self.base = Optional(ArcPointer(_indexed_run(table^, self.stats)))


struct ReadGenerationCache(Movable):
    """Collection-local publisher, accessed only under the collection writer lock.

    It owns the base and sealed runs, the bounded mutable head and the cached
    root. Each committed write is recorded into the head as a point state;
    capture freezes a copy of only the head's descriptors. Existing read
    handles keep old roots alive.
    """

    var root: Optional[ArcPointer[ReadGeneration]]
    var generation: UInt64
    """Generation of the last published manifest; 0 before the first."""
    var revision: UInt64
    var stats: ReadPublisherStats
    var _layers: List[ReadLayer]
    var _head: Optional[MemTable]
    var _head_bytes: Int
    var _frozen_head: Optional[ArcPointer[ReadRun]]
    var _sequence: UInt64
    var merge_delay_for_test: Float64
    var merge_failure_for_test: Bool

    def __init__(out self):
        self.root = Optional[ArcPointer[ReadGeneration]]()
        self.generation = 0
        self.revision = 0
        self.stats = ReadPublisherStats()
        self._layers = List[ReadLayer]()
        self._head = Optional[MemTable]()
        self._head_bytes = 0
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        self._sequence = 0
        self.merge_delay_for_test = 0
        self.merge_failure_for_test = False

    def invalidate(mut self):
        """Drop the cached root after a publication; runs stay valid."""
        self.root = Optional[ArcPointer[ReadGeneration]]()

    def publish(mut self, generation: UInt64):
        """Record a durable manifest publication and drop the cached root."""
        self.generation = generation
        self.invalidate()

    def reset(mut self):
        """Drop all derived state; the next capture builds a new base."""
        self.invalidate()
        self._layers = List[ReadLayer]()
        self._head = Optional[MemTable]()
        self._head_bytes = 0
        self._frozen_head = Optional[ArcPointer[ReadRun]]()

    def sealed_count(self) -> Int:
        return max(0, len(self._layers) - 1)

    def head_count(self) -> Int:
        return self._head.value().slot_count() if self._head else 0

    def record(mut self, memtable: MemTable, ids: List[Int], sequence: UInt64):
        """Record committed point states for IDs, after WAL and MemTable apply.

        `sequence` is the collection's accepted sequence after this write.

        Rollover happens here; merging the runs is the caller's job once
        `merge_due`. A failure after the commit cannot reject the write, so it
        drops derived state instead.
        """
        self.invalidate()
        if len(self._layers) == 0:
            return
        try:
            for id in ids:
                self._record_one(memtable, id)
            self._sequence = sequence
        except:
            self.reset()

    def merge_due(self) -> Bool:
        return self.sealed_count() >= MAX_SEALED_RUNS

    def capture_merge(self) -> SealedMerge:
        """Capture the base and every sealed run; the head stays mutable."""
        var runs = List[ArcPointer[ReadRun]](capacity=len(self._layers))
        for layer in self._layers:
            runs.append(layer.run)
        return SealedMerge(
            runs^, self.merge_delay_for_test, self.merge_failure_for_test
        )

    def publish_merge(mut self, var merge: SealedMerge) raises -> Bool:
        """Replace the merged prefix; later runs and the head are kept.

        False when the capture is stale: the publisher reset or rebuilt its
        base after the capture. Roots already published keep their chains.
        """
        var merged = len(merge.runs)
        if merged > len(self._layers) or not merge.base:
            return False
        for index in range(merged):
            if not (self._layers[index].run is merge.runs[index]):
                return False
        var base = merge.base.take()
        var hidden = List[Int]()
        for layer in range(merged, len(self._layers)):
            hidden.extend(
                _hidden_ordinals(base[].memtable, self._layers[layer].run[])
            )
        var layers = List[ReadLayer](capacity=len(self._layers) - merged + 1)
        layers.append(
            ReadLayer(
                base^, ArcPointer(_union(List[Int](), hidden^)), List[Int]()
            )
        )
        for layer in range(merged, len(self._layers)):
            layers.append(self._layers[layer].copy())
        self.invalidate()
        self._layers = layers^
        self.stats.descriptor_copies += merge.stats.descriptor_copies
        self.stats.payload_bytes += merge.stats.payload_bytes
        self.stats.sparse_bytes += merge.stats.sparse_bytes
        self.stats.consolidations += 1
        return True

    def merge_sealed_runs(mut self) raises:
        """Capture, build and publish in one step under the caller's lock."""
        var merge = self.capture_merge()
        merge.build()
        _ = self.publish_merge(merge^)

    def acquire(
        mut self,
        config: CollectionConfig,
        generation: UInt64,
        sequence: UInt64,
        memtable: MemTable,
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
            self._build_base(memtable, sequence)
        elif self._sequence != sequence:
            raise Error("read publisher missed a committed write")
        var layers = List[ReadLayer](capacity=len(self._layers) + 1)
        for layer in self._layers:
            layers.append(layer.copy())
        if self.head_count() > 0:
            if not self._frozen_head:
                # Descriptors only; the head is evaluated without indexes.
                var table = self._head.value().clone()
                self.stats.descriptor_copies += table.slot_count()
                self._frozen_head = Optional(
                    ArcPointer(ReadRun(table^, Optional[RunIndex]()))
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
                visible,
                pins,
            )
        )
        self.root = Optional(root)
        self.revision += 1
        return root^

    def _build_base(mut self, memtable: MemTable, sequence: UInt64) raises:
        var table = memtable.clone()
        self.stats.descriptor_copies += table.slot_count()
        var run = _indexed_run(table^, self.stats)
        self._layers = List[ReadLayer]()
        self._layers.append(
            ReadLayer(ArcPointer(run^), ArcPointer(List[Int]()), List[Int]())
        )
        self._head = Optional(MemTable(memtable.dimension))
        self._head_bytes = 0
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        self._sequence = sequence
        self.stats.base_builds += 1

    def _record_one(mut self, memtable: MemTable, id: Int) raises:
        var ordinal = memtable.ordinal_for(id)
        if ordinal < 0:
            raise Error("recorded ID is absent from the writer table")
        ref entry = memtable.entry_ref_at(ordinal)
        var incoming = _field_bytes(entry)
        var replaced = 0
        var existing = self._head.value().ordinal_for(id)
        if existing >= 0:
            replaced = _field_bytes(self._head.value().entry_ref_at(existing))
        var others = self.head_count() - (1 if existing >= 0 else 0)
        # A record that would overflow a non-empty head starts a new one, so a
        # legal oversized record gets its own run instead of a rejection.
        if (
            others > 0
            and self._head_bytes - replaced + incoming > HEAD_MAX_BYTES
        ):
            self._seal()
            replaced = 0
        # The frozen copy belongs to published roots; the next capture needs
        # a new one. The mutable head is never shared.
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        self._head.value().put(entry.clone())
        self._head_bytes += incoming - replaced
        self.stats.descriptor_copies += 1
        if (
            self.head_count() >= HEAD_MAX_POINTS
            or self._head_bytes >= HEAD_MAX_BYTES
        ):
            self._seal()

    def _seal(mut self) raises:
        """Move the head into a sealed run; only its indexes are built."""
        var table = self._head.take()
        self._head = Optional(MemTable(table.dimension))
        self._head_bytes = 0
        self._frozen_head = Optional[ArcPointer[ReadRun]]()
        var run = ArcPointer(_indexed_run(table^, self.stats))
        for layer in range(len(self._layers)):
            var added = _hidden_ordinals(
                self._layers[layer].run[].memtable, run[]
            )
            if len(added) == 0:
                continue
            # Replace the shared list; roots already published keep the old one.
            self._layers[layer].sealed_hidden = ArcPointer(
                _union(self._layers[layer].sealed_hidden[], added^)
            )
        self._layers.append(
            ReadLayer(run^, ArcPointer(List[Int]()), List[Int]())
        )
        self.stats.rollovers += 1


def _indexed_run(
    var table: MemTable, mut stats: ReadPublisherStats
) raises -> ReadRun:
    """Index one run's slots; field owners stay shared, not copied."""
    var metadata = MetadataIndex()
    var sparse = SparseIndex()
    metadata.begin_bulk()
    for ordinal in range(table.slot_count()):
        ref entry = table.entry_ref_at(ordinal)
        if entry.tombstone:
            metadata.delete(entry.id)
            continue
        stats.payload_bytes += entry.payload_bytes()
        var fields = clone_fields(entry.fields())
        metadata.upsert(entry.id, fields^)
        if entry.has_sparse():
            stats.sparse_bytes += entry.sparse_bytes()
            sparse.upsert(entry.id, entry.sparse())
    metadata.finish_bulk()
    if metadata.slot_count() != table.slot_count():
        raise Error("snapshot metadata slot alignment failed")
    return ReadRun(table^, Optional(RunIndex(metadata^, sparse^)))


def _hidden_ordinals(older: MemTable, newer: ReadRun) raises -> List[Int]:
    """Ordinals of `older` whose IDs have a state in the newer run."""
    ref table = newer.memtable
    var hidden = List[Int]()
    for slot in range(table.slot_count()):
        var ordinal = older.ordinal_for(table.id_at(slot))
        if ordinal >= 0:
            hidden.append(ordinal)
    return hidden^


def _union(existing: List[Int], var added: List[Int]) -> List[Int]:
    """Sorted, duplicate-free union of two ordinal lists."""
    added.extend(existing.copy())
    sort(Span(added))
    var unique = List[Int](capacity=len(added))
    for ordinal in added:
        if len(unique) == 0 or unique[len(unique) - 1] != ordinal:
            unique.append(ordinal)
    return unique^


def _field_bytes(entry: MemTableEntry) -> Int:
    return entry.dense_bytes() + entry.payload_bytes() + entry.sparse_bytes()


def _sparse_dot(
    query: List[SparseElement], elements: List[SparseElement]
) -> Optional[Float32]:
    """Merge two ascending term lists; None when no term is shared."""
    var score = Optional[Float32]()
    var position = 0
    for query_element in query:
        while (
            position < len(elements)
            and elements[position].term_id < query_element.term_id
        ):
            position += 1
        if position == len(elements):
            break
        if elements[position].term_id != query_element.term_id:
            continue
        var contribution = query_element.weight * elements[position].weight
        if score:
            score = Optional(score.value() + contribution)
        else:
            score = Optional(contribution)
    return score


def contains_sorted(values: List[Int], value: Int) -> Bool:
    var low = 0
    var high = len(values)
    while low < high:
        var middle = (low + high) // 2
        if values[middle] < value:
            low = middle + 1
        else:
            high = middle
    return low < len(values) and values[low] == value
