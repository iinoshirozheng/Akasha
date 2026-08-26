from akasha.index.sparse import SparseIndex
from akasha.storage.filesystem import (
    atomic_replace,
    path_exists,
    sync_directory,
)
from akasha.storage.manifest import (
    load_manifest,
    Manifest,
    publish_manifest,
    SegmentDescriptor,
)
from akasha.storage.memtable import MemTable
from akasha.storage.segment import (
    read_segment,
    SEGMENT_KIND_BASE,
    SEGMENT_KIND_DELTA,
    write_segment_v3,
)
from akasha.storage.sparse_store import (
    read_sparse_segment,
    read_sparse_snapshot,
    SPARSE_SEGMENT_KIND_BASE,
    SPARSE_SEGMENT_KIND_DELTA,
    SparseWalRecord,
    write_sparse_segment,
)


struct CommittedCompactionResult(Movable):
    var compacted: Bool
    var previous_generation: UInt64
    var removed_files: List[String]

    def __init__(
        out self,
        compacted: Bool,
        previous_generation: UInt64,
        var removed_files: List[String],
    ):
        self.compacted = compacted
        self.previous_generation = previous_generation
        self.removed_files = removed_files^

    @staticmethod
    def no_change() -> CommittedCompactionResult:
        return CommittedCompactionResult(False, 0, List[String]())


def compact_committed_segments(
    directory: String, dimension: Int
) raises -> CommittedCompactionResult:
    """Compact only manifest-committed state; a newer WAL remains untouched."""
    if not path_exists(directory + "/manifest.bin"):
        return CommittedCompactionResult.no_change()
    var previous = load_manifest(directory, dimension)
    if len(previous.segments) <= 1:
        return CommittedCompactionResult.no_change()
    if previous.generation == UInt64.MAX:
        raise Error("manifest generation exhausted")

    var memtable = _load_dense(directory, dimension, previous)
    var sparse = _load_sparse(directory, memtable, previous)
    var sequence = previous.last_sequence

    var sparse_name = "sparse-base-" + String(sequence) + ".bin"
    var sparse_temporary = directory + "/" + sparse_name + ".tmp"
    var sparse_mutations = List[SparseWalRecord]()
    var sparse_records = sparse.records()
    for index in range(len(sparse_records)):
        var elements = sparse_records[index].elements.copy()
        sparse_mutations.append(
            SparseWalRecord.upsert(
                sequence, sparse_records[index].id, elements^
            )
        )
    var sparse_checksum = write_sparse_segment(
        sparse_temporary,
        SPARSE_SEGMENT_KIND_BASE,
        0,
        sequence,
        sparse_mutations,
    )
    atomic_replace(sparse_temporary, directory + "/" + sparse_name)
    sync_directory(directory)

    var segment_name = "segment-base-" + String(sequence) + ".bin"
    var segment_temporary = directory + "/" + segment_name + ".tmp"
    var live_entries = memtable.live_entries()
    var checksum = write_segment_v3(
        segment_temporary,
        dimension,
        SEGMENT_KIND_BASE,
        0,
        sequence,
        live_entries,
    )
    atomic_replace(segment_temporary, directory + "/" + segment_name)
    sync_directory(directory)

    var descriptors = List[SegmentDescriptor]()
    descriptors.append(
        SegmentDescriptor.with_sparse(
            1,
            0,
            sequence,
            checksum,
            segment_name,
            sparse_checksum,
            sparse_name,
        )
    )
    var compacted = Manifest.with_segments(
        dimension,
        previous.generation + 1,
        sequence,
        descriptors^,
    )
    publish_manifest(directory, compacted)

    var removed = List[String]()
    for index in range(len(previous.segments)):
        if previous.segments[index].name != segment_name:
            removed.append(directory + "/" + previous.segments[index].name)
        if (
            previous.segments[index].sparse_name.byte_length() > 0
            and previous.segments[index].sparse_name != sparse_name
        ):
            removed.append(
                directory + "/" + previous.segments[index].sparse_name
            )
    return CommittedCompactionResult(True, previous.generation, removed^)


def _load_dense(
    directory: String, dimension: Int, manifest: Manifest
) raises -> MemTable:
    var memtable = MemTable(dimension)
    for index in range(len(manifest.segments)):
        var snapshot = read_segment(
            directory + "/" + manifest.segments[index].name, dimension
        )
        if (
            snapshot.min_sequence != manifest.segments[index].min_sequence
            or snapshot.last_sequence != manifest.segments[index].max_sequence
            or snapshot.checksum != manifest.segments[index].checksum
        ):
            raise Error("manifest and dense segment mismatch")
        if (
            manifest.segments[index].level == 0
            and snapshot.kind != SEGMENT_KIND_DELTA
        ):
            raise Error("level-zero manifest entry must be a dense delta")
        if (
            manifest.segments[index].level > 0
            and snapshot.kind != SEGMENT_KIND_BASE
        ):
            raise Error("compacted manifest entry must be a dense base")
        memtable.apply_recovered_entries(snapshot.entries)
    return memtable^


def _load_sparse(
    directory: String, memtable: MemTable, manifest: Manifest
) raises -> SparseIndex:
    var sparse = SparseIndex()
    for index in range(len(manifest.segments)):
        if manifest.segments[index].sparse_name.byte_length() == 0:
            var legacy_path = (
                directory
                + "/sparse-"
                + String(manifest.segments[index].max_sequence)
                + ".bin"
            )
            if path_exists(legacy_path):
                var legacy = read_sparse_snapshot(
                    legacy_path, manifest.segments[index].max_sequence
                )
                for record_index in range(len(legacy)):
                    sparse.upsert(
                        legacy[record_index].id,
                        legacy[record_index].elements,
                    )
            continue
        var segment = read_sparse_segment(
            directory + "/" + manifest.segments[index].sparse_name
        )
        if (
            segment.min_sequence != manifest.segments[index].min_sequence
            or segment.last_sequence != manifest.segments[index].max_sequence
            or segment.checksum != manifest.segments[index].sparse_checksum
        ):
            raise Error("manifest and sparse segment mismatch")
        if (
            manifest.segments[index].level == 0
            and segment.kind != SPARSE_SEGMENT_KIND_DELTA
        ):
            raise Error("level-zero manifest entry must be a sparse delta")
        if (
            manifest.segments[index].level > 0
            and segment.kind != SPARSE_SEGMENT_KIND_BASE
        ):
            raise Error("compacted manifest entry must be a sparse base")
        for record_index in range(len(segment.records)):
            if segment.records[record_index].is_delete:
                sparse.delete(segment.records[record_index].id)
            else:
                sparse.upsert(
                    segment.records[record_index].id,
                    segment.records[record_index].elements,
                )

    var records = sparse.records()
    for record_index in range(len(records)):
        if not Bool(memtable.get(records[record_index].id)):
            sparse.delete(records[record_index].id)
    return sparse^
