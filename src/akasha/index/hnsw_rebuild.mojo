from akasha.common.config import CollectionConfig, ScalarKind
from akasha.index.hnsw import HnswIndex
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.storage.memtable import MemTable
from akasha.storage.read_generation import ReadGeneration
from std.atomic import Atomic
from std.memory import ArcPointer, bitcast
from std.time import sleep


comptime HNSW_REBUILD_TAIL_LIMIT = 1_024
comptime HNSW_REBUILD_ATTEMPTS = 4
comptime HNSW_REBUILD_CATCHUP_PASSES = 4


struct _RebuildOrdinal(Comparable, Copyable, Movable):
    """A lightweight deterministic maintenance ordering key."""

    var sequence: UInt64
    var id: Int
    var ordinal: Int

    def __init__(out self, sequence: UInt64, id: Int, ordinal: Int):
        self.sequence = sequence
        self.id = id
        self.ordinal = ordinal

    def __lt__(self, other: Self) -> Bool:
        if self.sequence != other.sequence:
            return self.sequence < other.sequence
        if self.id != other.id:
            return self.id < other.id
        return self.ordinal < other.ordinal


def build_hnsw(
    memtable: MemTable, config: CollectionConfig
) raises -> HnswIndex:
    """Stage a deterministic graph while borrowing authoritative vectors."""
    var order = List[_RebuildOrdinal]()
    for ordinal in range(memtable.slot_count()):
        if not memtable.is_live_at(ordinal):
            continue
        ref entry = memtable.entry_ref_at(ordinal)
        if not entry.has_dense():
            continue
        order.append(
            _RebuildOrdinal(entry.document_sequence, entry.id, ordinal)
        )
    sort(Span(order))

    var index = HnswIndex(config)
    for order_index in range(len(order)):
        ref entry = memtable.entry_ref_at(order[order_index].ordinal)
        if (
            entry.tombstone
            or entry.document_sequence != order[order_index].sequence
            or entry.id != order[order_index].id
        ):
            raise Error("HNSW rebuild source changed during staging")
        index.add(entry.id, entry.values())
    index.validate_structure()
    return index^


def restore_hnsw_overlay(
    mut index: SegmentedHnsw,
    memtable: MemTable,
    base_sequence: UInt64,
    var cached_delta: Optional[HnswIndex] = None,
) raises -> Int:
    """Reconcile a validated immutable base with fully recovered authority.

    Checkpoints/compaction may have discarded historical WAL and tombstones.
    Current document versions identify replacements; absence identifies deletes.
    Only changed vectors enter the delta, in the same deterministic build order.
    """
    if index.has_delta():
        raise Error("HNSW overlay restoration requires a clean base")
    var removed = List[Int]()
    for id in index._sources._state[].sources:
        var ordinal = memtable.ordinal_for(id)
        if (
            ordinal < 0
            or not memtable.is_live_at(ordinal)
            or not memtable.entry_ref_at(ordinal).has_dense()
        ):
            removed.append(id)
    var order = List[_RebuildOrdinal]()
    for ordinal in range(memtable.slot_count()):
        if not memtable.is_live_at(ordinal):
            continue
        ref entry = memtable.entry_ref_at(ordinal)
        if not entry.has_dense():
            continue
        if entry.document_sequence > base_sequence:
            order.append(
                _RebuildOrdinal(entry.document_sequence, entry.id, ordinal)
            )
        elif not index.contains_current(entry.id):
            raise Error("HNSW base omits unchanged authoritative ID")
    sort(Span(order))
    if cached_delta:
        # Reject cache mismatches before changing the clean base source map.
        # Graph structure/config were fully checked by the snapshot decoder.
        try:
            _validate_cached_delta(cached_delta.value(), memtable, order)
        except:
            cached_delta = None
    for id in removed:
        _ = index.delete(id)
    if cached_delta:
        var delta = cached_delta.take()
        delta._bind_distance_backend(index.distance_backend)
        for item in order:
            if index._sources.source_for(item.id) > 0:
                index._base_stale_count += 1
            index._sources.set_delta(item.id)
            index._record_mutation()
        index._delta = delta^
    else:
        for item in order:
            ref entry = memtable.entry_ref_at(item.ordinal)
            index.upsert(entry.id, entry.values())
    if index.current_point_count() != memtable.dense_live_count():
        raise Error(
            "restored HNSW coverage differs from default field authority"
        )
    index.validate_overlay()
    return min(len(removed) + len(order), index.config.delta_max_points)


def _validate_cached_delta(
    delta: HnswIndex,
    memtable: MemTable,
    order: List[_RebuildOrdinal],
) raises:
    """Bind each current cached row to its exact authoritative representation.
    """
    if delta.point_count() - delta.inactive_count() != len(order):
        raise Error("HNSW overlay cache current count differs from authority")
    for item in order:
        var slot = delta.graph.current_slot(item.id)
        if not slot:
            raise Error("HNSW overlay cache omits an authoritative ID")
        ref entry = memtable.entry_ref_at(item.ordinal)
        var prepared = delta.metric.prepare_graph_vector(entry.values())
        if delta.config.scalar_kind == ScalarKind.i8():
            var base = Int(slot.value()) * delta.dimension
            for component in range(delta.dimension):
                var code = Float32(
                    bitcast[DType.int8](
                        delta.graph.vector_bytes[base + component]
                    )
                )
                if code != prepared[component]:
                    raise Error(
                        "HNSW overlay cache vector differs from authority"
                    )
            if bitcast[DType.uint32](
                delta.graph._i8_vector_scale(slot.value())
            ) != bitcast[DType.uint32](prepared[delta.dimension]):
                raise Error("HNSW overlay cache scale differs from authority")
        else:
            for component in range(delta.dimension):
                if bitcast[DType.uint32](
                    delta.graph.vector_value(slot.value(), component)
                ) != bitcast[DType.uint32](prepared[component]):
                    raise Error(
                        "HNSW overlay cache vector differs from authority"
                    )


struct HnswRebuild(Movable):
    """Pinned build inputs and a bounded latest-state journal.

    build() and catch_up() run outside the collection writer lock, borrowing
    immutable inputs. record() and take_tail() run under that lock. Repeated
    IDs replace descriptors; they never copy dense bytes.
    """

    var root: ArcPointer[ReadGeneration]
    var tail: MemTable
    var sequence: UInt64
    var tail_start_sequence: UInt64
    var invalid: Bool
    var delay_for_test: Float64
    var catchup_delay_for_test: Float64
    var catchup_started_for_test: ArcPointer[Atomic[DType.int64]]

    def __init__(out self, var root: ArcPointer[ReadGeneration]) raises:
        self.tail = MemTable(root[].config.dimension)
        self.sequence = root[].sequence
        self.tail_start_sequence = root[].sequence
        self.root = root^
        self.invalid = False
        self.delay_for_test = 0.0
        self.catchup_delay_for_test = 0.0
        self.catchup_started_for_test = ArcPointer(Atomic[DType.int64](0))

    def record(mut self, memtable: MemTable, ids: List[Int], sequence: UInt64):
        """A journal failure cannot reject an already committed mutation."""
        if self.invalid:
            return
        try:
            for id in ids:
                var ordinal = memtable.ordinal_for(id)
                if ordinal < 0:
                    raise Error("HNSW rebuild journal missed an accepted ID")
                ref entry = memtable.entry_ref_at(ordinal)
                # Named/sparse-only writes advance coverage without changing
                # the default dense projection. Its removal becomes a delete.
                var dense_sequence = (
                    entry.document_sequence if entry.has_dense() else entry.sequence
                )
                if dense_sequence <= self.tail_start_sequence:
                    continue
                var previous = self.tail.ordinal_for(id)
                if previous < 0:
                    if self.tail.slot_count() == HNSW_REBUILD_TAIL_LIMIT:
                        self.invalid = True
                        return
                elif (
                    self.tail.entry_ref_at(previous).sequence == dense_sequence
                ):
                    continue
                self.tail.put(entry.dense_descriptor())
            self.sequence = sequence
        except:
            self.invalid = True

    def build(self) raises -> SegmentedHnsw:
        """Build and index all graph slots outside the writer lock."""
        if self.delay_for_test > 0:
            sleep(self.delay_for_test)
        var source = self.root[].dense_run()
        return SegmentedHnsw.from_owned(
            build_hnsw(source[].memtable, self.root[].config)
        )

    def take_tail(mut self) raises -> MemTable:
        """Rotate the writer journal by ownership transfer, without row work."""
        var replacement = MemTable(self.root[].config.dimension)
        var tail = self.tail^
        self.tail = replacement^
        self.tail_start_sequence = self.sequence
        return tail^

    def catch_up(self, tail: MemTable, mut candidate: SegmentedHnsw) raises:
        """Apply one detached bounded journal without holding writer."""
        if self.catchup_delay_for_test > 0:
            _ = self.catchup_started_for_test[].fetch_add(1)
            sleep(self.catchup_delay_for_test)
        var order = List[_RebuildOrdinal](capacity=tail.slot_count())
        for ordinal in range(tail.slot_count()):
            ref entry = tail.entry_ref_at(ordinal)
            order.append(_RebuildOrdinal(entry.sequence, entry.id, ordinal))
        sort(Span(order))
        for key in order:
            ref entry = tail.entry_ref_at(key.ordinal)
            if entry.tombstone:
                _ = candidate.delete(entry.id)
            else:
                candidate.upsert(entry.id, entry.values())
