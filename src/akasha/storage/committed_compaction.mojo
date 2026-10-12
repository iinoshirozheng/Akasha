from akasha.document.vector_schema import FieldCatalog
from akasha.storage.field_catalog import load_field_catalog
from akasha.storage.point_recovery import (
    is_point_checkpoint,
    load_point_checkpoint,
)
from akasha.storage.point_segment import encode_point_segment
from akasha.storage.checksum import BorrowedBinaryReader
from akasha.index.sparse import SparseIndex
from akasha.storage.filesystem import (
    create_file_exclusive,
    path_exists,
    remove_file_if_exists,
    sync_directory,
    write_file_sync,
)
from akasha.storage.manifest import (
    load_manifest,
    Manifest,
    publish_manifest,
    SegmentDescriptor,
)
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.lock import CollectionLock
from akasha.storage.memtable import MemTable
from akasha.storage.read_generation import ReadGenerationCache
from akasha.storage.retired_files import RetiredFileQueue
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
from std.memory import ArcPointer

# Job outputs are named <prefix><target generation>-<claim>.bin. Open-time
# cleanup checks manifest references and file leases before removing them.
comptime _SEGMENT_OUTPUT_PREFIX = "segment-compact-"
comptime _SPARSE_OUTPUT_PREFIX = "sparse-compact-"
comptime _OUTPUT_SUFFIX = ".bin"
comptime _MAX_OUTPUT_CLAIMS = 1024


comptime COMPACTION_ATTEMPTS = 4
"""Captures one foreground or background compaction job may lose in a row."""


struct CompactionInputs(Movable):
    """The committed state one compaction job captured under the writer lock."""

    var manifest: Manifest
    var source_lock: Optional[ArcPointer[CollectionLock]]
    var catalog: Optional[ArcPointer[FieldCatalog]]

    def __init__(out self, var manifest: Manifest):
        self.manifest = manifest^
        self.source_lock = None
        self.catalog = None


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


def begin_compaction(
    directory: String,
    dimension: Int,
    pins: ArcPointer[GenerationPinRegistry],
    *,
    var source_lock: Optional[ArcPointer[CollectionLock]] = None,
) raises -> Optional[CompactionInputs]:
    """Capture the committed inputs and pin them; None when nothing to merge.

    The caller holds the writer lock. The pin keeps the inputs readable until
    `finish_compaction` or a failed `build_compaction` releases it.
    """
    var inputs = capture_compaction_inputs(directory, dimension)
    if inputs:
        pins[].pin(inputs.value().manifest.generation)
        inputs.value().source_lock = source_lock^
    return inputs^


def build_compaction(
    directory: String,
    dimension: Int,
    mut inputs: CompactionInputs,
    pins: ArcPointer[GenerationPinRegistry],
) raises -> CompactionOutput:
    """Merge the pinned inputs without the writer lock; unpin on failure."""
    try:
        return build_compaction_output(directory, dimension, inputs)
    except error:
        pins[].unpin(inputs.manifest.generation)
        inputs.source_lock = None
        raise error^


def finish_compaction(
    directory: String,
    dimension: Int,
    mut inputs: CompactionInputs,
    output: CompactionOutput,
    cancelled: Bool,
    pins: ArcPointer[GenerationPinRegistry],
    retired: ArcPointer[RetiredFileQueue],
    read_generations: ArcPointer[ReadGenerationCache],
) raises -> Bool:
    """Publish a built job and queue its retired inputs; False when discarded.

    The caller holds the writer lock. A cancelled job or replaced inputs
    discard the output. A publish error keeps the files: the manifest rename
    may already be durable, and open() removes an unpublished output. After
    success the caller reclaims the queued paths outside the writer lock.
    """
    # Release the job's lease first so retirement sees reader pins only.
    pins[].unpin(inputs.manifest.generation)
    try:
        if cancelled:
            discard_compaction_output(directory, output)
            inputs.source_lock = None
            return False
        var replaced = publish_compaction_output(
            directory, dimension, inputs, output
        )
        if not replaced:
            discard_compaction_output(directory, output)
            inputs.source_lock = None
            return False
        read_generations[].publish(replaced.value() + 1)
        retired[].enqueue(compaction_input_paths(directory, inputs.manifest))
    except error:
        inputs.source_lock = None
        raise error^
    inputs.source_lock = None
    return True


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
    var catalog = Optional[ArcPointer[FieldCatalog]]()
    if is_point_checkpoint(directory, manifest):
        var identity = load_field_catalog(directory)
        if (
            identity.format_version != 2
            or identity.field_at(0).dimension != dimension
        ):
            raise Error("point compaction requires a matching field catalog")
        catalog = Optional(ArcPointer(identity^))
    var inputs = CompactionInputs(manifest^)
    inputs.catalog = catalog^
    return Optional(inputs^)


def build_compaction_output(
    directory: String, dimension: Int, inputs: CompactionInputs
) raises -> CompactionOutput:
    """Merge the captured inputs into new job-unique files and fsync them.

    Runs without the writer lock. Inputs are only read; on failure only the
    files this job created are removed.
    """
    if inputs.catalog:
        return _build_point_compaction(directory, inputs)
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
    if output.sparse_name.byte_length() > 0:
        remove_file_if_exists(directory + "/" + output.sparse_name)


def publish_compaction_output(
    directory: String,
    dimension: Int,
    inputs: CompactionInputs,
    output: CompactionOutput,
) raises -> Optional[UInt64]:
    """Rebase the output onto the current manifest and publish it.

    The caller holds the writer lock. Like RocksDB's version edit, the output
    replaces its inputs in the current manifest: segments committed after the
    capture are kept behind it, and the current last sequence and HNSW
    reference carry over because the live set is unchanged. Returns the
    replaced generation, or None when the inputs are no longer the leading
    run of the current manifest; that manifest is left untouched.
    """
    ref captured = inputs.manifest
    var current = load_manifest(directory, dimension)
    if len(current.segments) < len(captured.segments):
        return None
    for index in range(len(captured.segments)):
        if not _same_segment(captured.segments[index], current.segments[index]):
            return None
    if current.generation == UInt64.MAX:
        raise Error("manifest generation exhausted")
    var descriptors = List[SegmentDescriptor]()
    if output.sparse_name.byte_length() == 0:
        descriptors.append(
            SegmentDescriptor(
                1,
                0,
                captured.last_sequence,
                output.checksum,
                output.segment_name,
            )
        )
    else:
        descriptors.append(
            SegmentDescriptor.with_sparse(
                1,
                0,
                captured.last_sequence,
                output.checksum,
                output.segment_name,
                output.sparse_checksum,
                output.sparse_name,
            )
        )
    for index in range(len(captured.segments), len(current.segments)):
        if current.segments[index].min_sequence <= captured.last_sequence:
            raise Error("appended segment overlaps the compaction output")
        descriptors.append(current.segments[index].clone())
    var compacted: Manifest
    if Bool(current.hnsw_name):
        compacted = Manifest.with_hnsw(
            dimension,
            current.generation + 1,
            current.last_sequence,
            descriptors^,
            current.hnsw_name.value(),
            current.hnsw_checksum.value(),
            current.hnsw_config_fingerprint.value(),
            current.hnsw_point_count.value(),
            format_version=current.format_version,
        )
    else:
        compacted = Manifest.with_segments(
            dimension,
            current.generation + 1,
            current.last_sequence,
            descriptors^,
        )
    publish_manifest(directory, compacted)
    return current.generation


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


def _same_segment(
    captured: SegmentDescriptor, current: SegmentDescriptor
) -> Bool:
    return (
        captured.level == current.level
        and captured.min_sequence == current.min_sequence
        and captured.max_sequence == current.max_sequence
        and captured.checksum == current.checksum
        and captured.name == current.name
        and captured.sparse_checksum == current.sparse_checksum
        and captured.sparse_name == current.sparse_name
    )


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


def _build_point_compaction(
    directory: String, inputs: CompactionInputs
) raises -> CompactionOutput:
    var table = load_point_checkpoint(
        directory, inputs.manifest, inputs.catalog.value().copy()
    )
    var bytes = encode_point_segment(
        1,
        0,
        inputs.manifest.last_sequence,
        table.live_points(),
        inputs.catalog.value()[],
    )
    var reader = BorrowedBinaryReader(Span(bytes)[len(bytes) - 4 :])
    var checksum = reader.read_u32()
    var name = _claim_output(
        directory, _SEGMENT_OUTPUT_PREFIX, inputs.manifest.generation + 1
    )
    try:
        write_file_sync(directory + "/" + name, bytes)
        sync_directory(directory)
    except error:
        try:
            remove_file_if_exists(directory + "/" + name)
        except:
            pass
        raise error^
    return CompactionOutput(name, checksum, "", 0)
