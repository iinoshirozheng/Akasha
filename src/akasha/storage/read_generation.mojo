"""Immutable read owners, separate from mutable collection and snapshot handles."""

from akasha.common.config import CollectionConfig
from akasha.document.record import clone_fields
from akasha.index.metadata import MetadataIndex
from akasha.index.sparse import SparseIndex
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable
from std.memory import ArcPointer


struct ReadBase(Movable):
    """One sealed base with aligned dense, payload and sparse read state.

    Only construction mutates this run. Bounded head/sealed deltas will sit
    alongside this owner in ReadGeneration; they must not mutate this base.
    """

    var memtable: MemTable
    var metadata: MetadataIndex
    var sparse: SparseIndex

    def __init__(
        out self, var memtable: MemTable, var metadata: MetadataIndex,
        var sparse: SparseIndex,
    ):
        self.memtable = memtable^
        self.metadata = metadata^
        self.sparse = sparse^


struct ReadGeneration(Movable):
    """One published view; its last strong owner releases its generation pin."""

    var config: CollectionConfig
    var generation: UInt64
    var sequence: UInt64
    var revision: UInt64
    var _base: ArcPointer[ReadBase]
    var _pins: ArcPointer[GenerationPinRegistry]

    def __init__(
        out self, config: CollectionConfig, generation: UInt64,
        sequence: UInt64, revision: UInt64, var base: ArcPointer[ReadBase],
        var pins: ArcPointer[GenerationPinRegistry],
    ):
        self.config = config.copy()
        self.generation = generation
        self.sequence = sequence
        self.revision = revision
        self._base = base^
        self._pins = pins^
        self._pins[].pin(generation)

    def __deinit__(deinit self):
        self._pins[].unpin(self.generation)

    @staticmethod
    def capture(
        config: CollectionConfig, generation: UInt64, sequence: UInt64,
        revision: UInt64, memtable: MemTable, sparse: SparseIndex,
        pins: ArcPointer[GenerationPinRegistry],
    ) raises -> ArcPointer[ReadGeneration]:
        config.validate()
        if memtable.dimension != config.dimension:
            raise Error("snapshot dimension mismatch")
        if memtable.last_sequence > sequence:
            raise Error("snapshot sequence precedes memtable")
        # This first base build still copies all data. Pin only after every
        # fallible build step succeeds; failed capture leaves no lease behind.
        var owned = memtable.clone()
        var metadata = _build_metadata(owned)
        var owned_sparse = sparse.clone()
        var base = ArcPointer(ReadBase(owned^, metadata^, owned_sparse^))
        return ArcPointer(
            ReadGeneration(config, generation, sequence, revision, base^, pins)
        )


struct ReadGenerationCache(Movable):
    """Collection-local publisher, accessed only under the collection writer lock.

    Each open has its own cache. Revision advances on successful publication;
    writes and layout publications invalidate the cached owner. Existing read
    handles keep old roots alive independently of this cache.
    """

    var root: Optional[ArcPointer[ReadGeneration]]
    var revision: UInt64

    def __init__(out self):
        self.root = Optional[ArcPointer[ReadGeneration]]()
        self.revision = 0

    def invalidate(mut self):
        self.root = Optional[ArcPointer[ReadGeneration]]()

    def acquire(
        mut self, config: CollectionConfig, generation: UInt64,
        sequence: UInt64, memtable: MemTable, sparse: SparseIndex,
        pins: ArcPointer[GenerationPinRegistry],
    ) raises -> ArcPointer[ReadGeneration]:
        if self.root:
            ref current = self.root.value()[]
            if (
                current.generation == generation and current.sequence == sequence
                and current.config.fingerprint() == config.fingerprint()
            ):
                return self.root.value()
        if self.revision == UInt64.MAX:
            raise Error("read view revision exhausted")
        var root = ReadGeneration.capture(
            config, generation, sequence, self.revision + 1, memtable, sparse, pins
        )
        self.root = Optional(root)
        self.revision += 1
        return root^


def _build_metadata(memtable: MemTable) raises -> MetadataIndex:
    var index = MetadataIndex()
    index.begin_bulk()
    for ordinal in range(memtable.slot_count()):
        ref entry = memtable.entry_ref_at(ordinal)
        if entry.tombstone:
            index.delete(entry.id)
        else:
            var fields = clone_fields(entry.fields)
            index.upsert(entry.id, fields^)
    index.finish_bulk()
    if index.slot_count() != memtable.slot_count():
        raise Error("snapshot metadata slot alignment failed")
    return index^
