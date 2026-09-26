from akasha.index.sparse import SparseIndex
from akasha.storage.filesystem import (
    create_file_exclusive,
    path_exists,
    remove_file_if_exists,
    sync_directory,
)
from akasha.storage.manifest import (
    load_manifest,
    Manifest,
    publish_manifest,
    read_manifest_bytes,
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
from std.os import listdir, remove

# Job outputs are named <prefix><target generation>-<claim>.bin. The target
# generation lets open() tell unpublished outputs from committed files.
comptime _SEGMENT_OUTPUT_PREFIX = "segment-compact-"
comptime _SPARSE_OUTPUT_PREFIX = "sparse-compact-"
comptime _OUTPUT_SUFFIX = ".bin"
comptime _MAX_OUTPUT_CLAIMS = 1024


struct CompactionInputs(Movable):
    """The committed state one compaction job captured under the writer lock."""

    var manifest: Manifest
    var manifest_bytes: List[UInt8]
    """Exact published bytes; publish requires them to be unchanged."""

    def __init__(
        out self, var manifest: Manifest, var manifest_bytes: List[UInt8]
    ):
        self.manifest = manifest^
        self.manifest_bytes = manifest_bytes^


struct CompactionOutput(Movable):
    """Durable, not yet published files one compaction job wrote."""

    var segment_name: String
    var checksum: UInt32
    var sparse_name: String
    var sparse_checksum: UInt32

    def __init__(
        out self,
        segment_name: String,
        checksum: UInt32,
        sparse_name: String,
        sparse_checksum: UInt32,
    ):
        self.segment_name = segment_name
        self.checksum = checksum
        self.sparse_name = sparse_name
        self.sparse_checksum = sparse_checksum


struct CommittedCompactionResult(Movable):
    var compacted: Bool
    var previous_generation: UInt64
    var generation: UInt64
    """Generation of the published manifest when `compacted`."""
    var removed_files: List[String]

    def __init__(
        out self,
        compacted: Bool,
        previous_generation: UInt64,
        generation: UInt64,
        var removed_files: List[String],
    ):
        self.compacted = compacted
        self.previous_generation = previous_generation
        self.generation = generation
        self.removed_files = removed_files^

    @staticmethod
    def no_change() -> CommittedCompactionResult:
        return CommittedCompactionResult(False, 0, 0, List[String]())


def compact_committed_segments(
    directory: String, dimension: Int
) raises -> CommittedCompactionResult:
    """Capture, build and publish in one step under the caller's writer lock."""
    var inputs = capture_compaction_inputs(directory, dimension)
    if not inputs:
        return CommittedCompactionResult.no_change()
    var output = build_compaction_output(directory, dimension, inputs.value())
    if not publish_compaction_output(
        directory, dimension, inputs.value(), output
    ):
        discard_compaction_output(directory, output)
        raise Error("manifest changed under the writer lock")
    var previous = inputs.value().manifest.generation
    return CommittedCompactionResult(
        True,
        previous,
        previous + 1,
        compaction_input_paths(directory, inputs.value().manifest),
    )


def capture_compaction_inputs(
    directory: String, dimension: Int
) raises -> Optional[CompactionInputs]:
    """Read the committed segments to merge; None when fewer than two."""
    if not path_exists(directory + "/manifest.bin"):
        return None
    var manifest = load_manifest(directory, dimension)
    if len(manifest.segments) <= 1:
        return None
    if manifest.generation == UInt64.MAX:
        raise Error("manifest generation exhausted")
    return CompactionInputs(manifest^, read_manifest_bytes(directory))


def build_compaction_output(
    directory: String, dimension: Int, inputs: CompactionInputs
) raises -> CompactionOutput:
    """Merge the captured inputs into new job-unique files and fsync them.

    Runs without the writer lock. Inputs are only read; on failure only the
    files this job created are removed.
    """
    var memtable = _load_dense(directory, dimension, inputs.manifest)
    var sparse = _load_sparse(directory, memtable, inputs.manifest)
    var sequence = inputs.manifest.last_sequence
    var target = inputs.manifest.generation + 1

    var sparse_name = _claim_output(directory, _SPARSE_OUTPUT_PREFIX, target)
    var segment_name = String()
    try:
        segment_name = _claim_output(directory, _SEGMENT_OUTPUT_PREFIX, target)
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
            directory + "/" + sparse_name,
            SPARSE_SEGMENT_KIND_BASE,
            0,
            sequence,
            sparse_mutations,
        )
        var checksum = write_segment_v3(
            directory + "/" + segment_name,
            dimension,
            SEGMENT_KIND_BASE,
            0,
            sequence,
            memtable.live_entries(),
        )
        sync_directory(directory)
        return CompactionOutput(
            segment_name, checksum, sparse_name, sparse_checksum
        )
    except error:
        # Keep the build error; a file left behind is unpublished and open()
        # removes it.
        try:
            remove_file_if_exists(directory + "/" + sparse_name)
            if segment_name.byte_length() > 0:
                remove_file_if_exists(directory + "/" + segment_name)
        except:
            pass
        raise error^


def discard_compaction_output(
    directory: String, output: CompactionOutput
) raises:
    """Remove one unpublished job's files; never touches any input."""
    remove_file_if_exists(directory + "/" + output.segment_name)
    remove_file_if_exists(directory + "/" + output.sparse_name)


def publish_compaction_output(
    directory: String,
    dimension: Int,
    inputs: CompactionInputs,
    output: CompactionOutput,
) raises -> Bool:
    """Publish generation G + 1 only if the manifest is still the captured one.

    The caller holds the writer lock. False means another publish won; the
    newer manifest is left untouched.
    """
    if read_manifest_bytes(directory) != inputs.manifest_bytes:
        return False
    ref previous = inputs.manifest
    var descriptors = List[SegmentDescriptor]()
    descriptors.append(
        SegmentDescriptor.with_sparse(
            1,
            0,
            previous.last_sequence,
            output.checksum,
            output.segment_name,
            output.sparse_checksum,
            output.sparse_name,
        )
    )
    var compacted: Manifest
    if Bool(previous.hnsw_name):
        compacted = Manifest.with_hnsw(
            dimension,
            previous.generation + 1,
            previous.last_sequence,
            descriptors^,
            previous.hnsw_name.value(),
            previous.hnsw_checksum.value(),
            previous.hnsw_config_fingerprint.value(),
            previous.hnsw_point_count.value(),
        )
    else:
        compacted = Manifest.with_segments(
            dimension,
            previous.generation + 1,
            previous.last_sequence,
            descriptors^,
        )
    publish_manifest(directory, compacted)
    return True


def compaction_input_paths(
    directory: String, manifest: Manifest
) -> List[String]:
    """Paths a publish replaces: every dense and sparse file of the inputs."""
    var paths = List[String]()
    for index in range(len(manifest.segments)):
        paths.append(directory + "/" + manifest.segments[index].name)
        if manifest.segments[index].sparse_name.byte_length() > 0:
            paths.append(directory + "/" + manifest.segments[index].sparse_name)
    return paths^


def remove_unpublished_compaction_outputs(
    directory: String, committed_generation: UInt64
) raises:
    """Remove job outputs whose target generation was never published.

    Every published output targets a generation at or below the committed
    one, so this never removes a committed or pinned file.
    """
    var removed = False
    for name in listdir(directory):
        var target = _output_target(name)
        if target and target.value() > committed_generation:
            remove(directory + "/" + name)
            removed = True
    if removed:
        sync_directory(directory)


def _claim_output(
    directory: String, prefix: String, target: UInt64
) raises -> String:
    for claim in range(_MAX_OUTPUT_CLAIMS):
        var name = (
            prefix + String(target) + "-" + String(claim) + _OUTPUT_SUFFIX
        )
        if create_file_exclusive(directory + "/" + name):
            return name
    raise Error("no free compaction output name")


def _output_target(name: String) -> Optional[UInt64]:
    var rest: String
    if name.startswith(_SEGMENT_OUTPUT_PREFIX):
        rest = String(name.removeprefix(_SEGMENT_OUTPUT_PREFIX))
    elif name.startswith(_SPARSE_OUTPUT_PREFIX):
        rest = String(name.removeprefix(_SPARSE_OUTPUT_PREFIX))
    else:
        return None
    if not rest.endswith(_OUTPUT_SUFFIX):
        return None
    var parts = rest.removesuffix(_OUTPUT_SUFFIX).split("-")
    if len(parts) != 2:
        return None
    try:
        var target = Int(parts[0])
        _ = Int(parts[1])
        if target < 0:
            return None
        return UInt64(target)
    except:
        return None


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
