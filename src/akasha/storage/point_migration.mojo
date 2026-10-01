from akasha.document.point_state import PointState
from akasha.document.vector_schema import FieldCatalog
from akasha.storage.legacy_recovery import preflight_legacy_with_reader
from akasha.storage.memtable import MemTable
from akasha.storage.point_table import PointTable
from akasha.storage.point_wal import FieldWalReader, PointWalBatch
from akasha.storage.sparse_store import SparseWalReplayState
from akasha.storage.wal import LegacyWalSource, WalRecord
from std.memory import ArcPointer
from std.math import isfinite


struct _LegacyPrefix(LegacyWalSource):
    var reader: FieldWalReader
    var first_point_batch: Optional[PointWalBatch]
    var _done: Bool
    var _legacy_length: Int

    def __init__(out self, var reader: FieldWalReader):
        self.reader = reader^
        self.first_point_batch = Optional[PointWalBatch]()
        self._done = False
        self._legacy_length = 0

    def read_next(mut self) raises -> List[WalRecord]:
        if self._done:
            return List[WalRecord]()
        var next = self.reader.read_next()
        if not next:
            self._done = True
            return List[WalRecord]()
        var envelope = next.take()
        if envelope.is_legacy():
            self._legacy_length = self.reader.valid_length
            return envelope^.take_legacy_records()
        self._done = True
        self.first_point_batch = Optional(envelope^.take_point_batch())
        return List[WalRecord]()

    def accepted_length(self) -> Int:
        return self._legacy_length

    def total_length(self) -> Int:
        return self.reader.source_length


@fieldwise_init
struct PointRecovery(Movable):
    var points: Optional[PointTable]
    var sparse_wal: Optional[SparseWalReplayState]
    var generation: UInt64
    var snapshot_sequence: UInt64
    var wal_valid_length: Int
    var wal_source_length: Int
    var point_checkpoint: Bool


def preflight_migrating_points(
    path: String, var catalog: ArcPointer[FieldCatalog]
) raises -> PointRecovery:
    """Recover legacy checkpoints plus a mixed WAL into typed point authority.

    Finish both legacy streams at the exact catalog cutover before applying any
    field patches. Migration shares validated legacy field owners and anchors every
    point at C while preserving its real legacy document sequence D. The caller
    holds collection exclusion and publishes/repairs only after this returns.
    New-format checkpoints are handled by the point checkpoint loader, not here.
    """
    var prefix = _LegacyPrefix(
        FieldWalReader(path + "/wal.bin", catalog.copy())
    )
    var legacy = preflight_legacy_with_reader(
        path, catalog[].field_at(0).dimension, prefix
    )
    var cutover = catalog[].legacy_cutover_sequence
    if legacy.last_sequence != cutover:
        raise Error("legacy accepted sequence does not match field cutover")

    var points = point_table_from_legacy(
        legacy.memtable.value(), catalog.copy()
    )
    if prefix.first_point_batch:
        points.replay(prefix.first_point_batch.value())
        prefix.first_point_batch = Optional[PointWalBatch]()
    while True:
        var next = prefix.reader.read_next()
        if not next:
            break
        if next.value().is_legacy():
            raise Error("legacy record follows field-aware WAL prefix")
        points.replay(next.value().point_batch())
    return PointRecovery(
        Optional(points^),
        Optional(legacy.sparse_wal.take()),
        legacy.generation,
        legacy.snapshot_sequence,
        prefix.reader.valid_length,
        prefix.reader.source_length,
        False,
    )


def point_table_from_legacy(
    memtable: MemTable, var catalog: ArcPointer[FieldCatalog]
) raises -> PointTable:
    """Convert fully replayed legacy authority once at the catalog cutover."""
    var cutover = catalog[].legacy_cutover_sequence
    var states = List[PointState](capacity=memtable.slot_count())
    for ordinal in range(memtable.slot_count()):
        ref entry = memtable.entry_ref_at(ordinal)
        if entry.tombstone:
            states.append(PointState.deleted(entry.id, cutover))
            continue
        # Old low-level codecs preserve arbitrary F32 bits. Reject values
        # outside the new authority contract before sharing those owners.
        for value in entry.values():
            if not isfinite(value):
                raise Error("legacy vectors must be finite for field migration")
        var point = entry.to_point()
        point.sequence = cutover
        states.append(point^)
    return PointTable(catalog^, cutover, states^)
