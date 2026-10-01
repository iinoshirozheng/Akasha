from akasha.index.sparse import SparseIndex
from akasha.storage.filesystem import path_exists
from akasha.storage.manifest import load_manifest
from akasha.storage.memtable import MemTable
from akasha.storage.segment import (
    read_segment,
    SEGMENT_KIND_BASE,
    SEGMENT_KIND_DELTA,
)
from akasha.storage.sparse_store import (
    preflight_sparse_wal,
    read_sparse_segment,
    read_sparse_snapshot,
    SparseWalRecord,
    SparseWalReplayState,
    SPARSE_SEGMENT_KIND_BASE,
    SPARSE_SEGMENT_KIND_DELTA,
)
from akasha.storage.wal import LegacyWalSource, WalReader
from std.collections import Dict


@fieldwise_init
struct LegacyRecovery(Movable):
    """Read-only recovery output; the owner decides when publication is safe."""

    var memtable: Optional[MemTable]
    var sparse: Optional[SparseIndex]
    var sparse_pending: Optional[List[SparseWalRecord]]
    var sparse_wal: Optional[SparseWalReplayState]
    var checkpoint_live_ids: Optional[Dict[Int, Bool]]
    var snapshot_sequence: UInt64
    var last_sequence: UInt64
    var generation: UInt64
    var wal_valid_length: Int
    var wal_source_length: Int


def preflight_legacy_authority(
    path: String, dimension: Int
) raises -> LegacyRecovery:
    """Validate and recover supported legacy segments and both WALs.

    The caller holds collection exclusion throughout preflight and publication.
    No identity, derived cache, lock file or tail repair is written here.
    Sparse ties precede dense deletes, including delete/reinsert recovery.
    """
    var reader = WalReader(path + "/wal.bin", dimension)
    return preflight_legacy_with_reader(path, dimension, reader)


def preflight_legacy_with_reader[
    Reader: LegacyWalSource
](path: String, dimension: Int, mut dense_wal: Reader) raises -> LegacyRecovery:
    """Reuse legacy ordering while a migration reader bounds the old prefix."""
    var memtable = MemTable(dimension)
    var snapshot_sequence = UInt64(0)
    var cache_generation = UInt64(0)
    var manifest_path = path + "/manifest.bin"
    if path_exists(manifest_path):
        var manifest = load_manifest(path, dimension)
        cache_generation = manifest.generation
        for segment_index in range(len(manifest.segments)):
            var snapshot = read_segment(
                path + "/" + manifest.segments[segment_index].name,
                dimension,
            )
            if (
                snapshot.min_sequence
                != manifest.segments[segment_index].min_sequence
                or snapshot.last_sequence
                != manifest.segments[segment_index].max_sequence
            ):
                raise Error("manifest and segment sequence mismatch")
            if snapshot.checksum != manifest.segments[segment_index].checksum:
                raise Error("manifest and segment checksum mismatch")
            if (
                manifest.segments[segment_index].level == 0
                and snapshot.kind != SEGMENT_KIND_DELTA
            ):
                raise Error("level-zero manifest entry must be a delta")
            if (
                manifest.segments[segment_index].level > 0
                and snapshot.kind != SEGMENT_KIND_BASE
            ):
                raise Error("compacted manifest entry must be a base")
            memtable.apply_recovered_entries(snapshot.entries)
        snapshot_sequence = manifest.last_sequence

    # Preserve the exact committed dense identity before newer WAL replay.
    # A sidecar describes this checkpoint, not the post-WAL MemTable.
    var checkpoint_live_ids = Dict[Int, Bool]()
    for ordinal in range(memtable.slot_count()):
        if memtable.is_live_at(ordinal):
            checkpoint_live_ids[memtable.id_at(ordinal)] = True

    var sparse = SparseIndex()
    if path_exists(manifest_path):
        var sparse_manifest = load_manifest(path, dimension)
        var described_sparse_count = 0
        for descriptor_index in range(len(sparse_manifest.segments)):
            if (
                sparse_manifest.segments[
                    descriptor_index
                ].sparse_name.byte_length()
                > 0
            ):
                described_sparse_count += 1
        if described_sparse_count == 0:
            var legacy_path = (
                path + "/sparse-" + String(snapshot_sequence) + ".bin"
            )
            if path_exists(legacy_path):
                var legacy_records = read_sparse_snapshot(
                    legacy_path, snapshot_sequence
                )
                for record_index in range(len(legacy_records)):
                    sparse.upsert(
                        legacy_records[record_index].id,
                        legacy_records[record_index].elements,
                    )
        else:
            for descriptor_index in range(len(sparse_manifest.segments)):
                if (
                    sparse_manifest.segments[
                        descriptor_index
                    ].sparse_name.byte_length()
                    == 0
                ):
                    var legacy_path = (
                        path
                        + "/sparse-"
                        + String(
                            sparse_manifest.segments[
                                descriptor_index
                            ].max_sequence
                        )
                        + ".bin"
                    )
                    if path_exists(legacy_path):
                        var legacy_records = read_sparse_snapshot(
                            legacy_path,
                            sparse_manifest.segments[
                                descriptor_index
                            ].max_sequence,
                        )
                        for record_index in range(len(legacy_records)):
                            sparse.upsert(
                                legacy_records[record_index].id,
                                legacy_records[record_index].elements,
                            )
                    continue
                var sparse_segment = read_sparse_segment(
                    path
                    + "/"
                    + sparse_manifest.segments[descriptor_index].sparse_name
                )
                if (
                    sparse_segment.min_sequence
                    != sparse_manifest.segments[descriptor_index].min_sequence
                    or sparse_segment.last_sequence
                    != sparse_manifest.segments[descriptor_index].max_sequence
                ):
                    raise Error("manifest and sparse segment sequence mismatch")
                if (
                    sparse_segment.checksum
                    != sparse_manifest.segments[
                        descriptor_index
                    ].sparse_checksum
                ):
                    raise Error("manifest and sparse segment checksum mismatch")
                if (
                    sparse_manifest.segments[descriptor_index].level == 0
                    and sparse_segment.kind != SPARSE_SEGMENT_KIND_DELTA
                ):
                    raise Error("level-zero sparse entry must be a delta")
                if (
                    sparse_manifest.segments[descriptor_index].level > 0
                    and sparse_segment.kind != SPARSE_SEGMENT_KIND_BASE
                ):
                    raise Error("compacted sparse entry must be a base")
                for record_index in range(len(sparse_segment.records)):
                    if sparse_segment.records[record_index].is_delete:
                        sparse.delete(sparse_segment.records[record_index].id)
                    else:
                        sparse.upsert(
                            sparse_segment.records[record_index].id,
                            sparse_segment.records[record_index].elements,
                        )
    var sparse_pending = List[SparseWalRecord]()
    var sparse_wal = preflight_sparse_wal(path + "/sparse.wal")
    # Merge the two WALs in accepted sequence order. Only one dense
    # envelope is retained; decoded values move directly into authority.
    # Sparse ties precede dense deletes, preserving the prior merge rule.
    var last_sequence = snapshot_sequence
    var sparse_index = 0
    while True:
        var dense_batch = dense_wal.read_next()
        if len(dense_batch) == 0:
            break
        for var dense in dense_batch^:
            while (
                sparse_index < len(sparse_wal.records)
                and sparse_wal.records[sparse_index].sequence <= dense.sequence
            ):
                last_sequence = max(
                    last_sequence,
                    _apply_recovered_sparse(
                        sparse_wal.records[sparse_index],
                        snapshot_sequence,
                        sparse,
                        sparse_pending,
                    ),
                )
                sparse_index += 1
            if dense.sequence <= snapshot_sequence:
                continue
            var id = dense.id
            var sequence = dense.sequence
            if dense.is_delete:
                memtable.apply_delete(id, sequence)
                if sparse.contains(id):
                    sparse.delete(id)
                    sparse_pending.append(SparseWalRecord.delete(sequence, id))
            else:
                var values = dense.take_values()
                var fields = dense.take_fields()
                memtable.apply_document_upsert(id, sequence, values^, fields^)
            last_sequence = max(last_sequence, sequence)
    while sparse_index < len(sparse_wal.records):
        last_sequence = max(
            last_sequence,
            _apply_recovered_sparse(
                sparse_wal.records[sparse_index],
                snapshot_sequence,
                sparse,
                sparse_pending,
            ),
        )
        sparse_index += 1
    var recovered_sparse = sparse.records()
    for index in range(len(recovered_sparse)):
        var ordinal = memtable.ordinal_for(recovered_sparse[index].id)
        if ordinal < 0 or not memtable.is_live_at(ordinal):
            sparse.delete(recovered_sparse[index].id)
            continue
        # The point state owns its sparse field, like dense and payload.
        memtable.set_sparse(
            recovered_sparse[index].id,
            recovered_sparse[index].elements.copy(),
        )

    return LegacyRecovery(
        Optional(memtable^),
        Optional(sparse^),
        Optional(sparse_pending^),
        Optional(sparse_wal^),
        Optional(checkpoint_live_ids^),
        snapshot_sequence,
        last_sequence,
        cache_generation,
        dense_wal.accepted_length(),
        dense_wal.total_length(),
    )


def _apply_recovered_sparse(
    record: SparseWalRecord,
    checkpoint_sequence: UInt64,
    mut sparse: SparseIndex,
    mut pending: List[SparseWalRecord],
) raises -> UInt64:
    if record.sequence <= checkpoint_sequence:
        return checkpoint_sequence
    if record.is_delete:
        sparse.delete(record.id)
    else:
        sparse.upsert(record.id, record.elements)
    pending.append(record.clone())
    return record.sequence
