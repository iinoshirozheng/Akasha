from akasha.storage.compaction import CompactionPolicy, select_point_merge_range
from akasha.document.vector_schema import FieldCatalog
from akasha.storage.field_catalog import load_field_catalog
from akasha.storage.point_recovery import (
    is_point_checkpoint,
)
from akasha.storage.point_merge import PointMerge
from akasha.index.sparse import SparseIndex
from akasha.storage.filesystem import (
    create_file_exclusive,
    path_exists,
    remove_file_if_exists,
    sync_directory,
)
from akasha.storage.manifest import (
    _validate_manifest_names,
    decode_manifest_bytes,
    load_manifest,
    Manifest,
    publish_manifest,
    read_manifest_bytes,
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
    """Committed files leased and revalidated against published authority."""

    var manifest: Manifest
    var first: Int
    var limit: Int
    var source_lock: Optional[ArcPointer[CollectionLock]]
    var catalog: Optional[ArcPointer[FieldCatalog]]

    def __init__(out self, var manifest: Manifest):
        self.first = 0
        self.limit = len(manifest.segments)
        self.manifest = manifest^
        self.source_lock = None
        self.catalog = None


@fieldwise_init
struct CompactionCapture(Movable):
    """A capture may have inputs, have no work, or need another attempt."""

    var inputs: Optional[CompactionInputs]
    var stale: Bool


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
    automatic: Bool = False,
) raises -> CompactionCapture:
    """Capture and lease committed inputs without holding the writer lock.

    The caller keeps the collection lock alive. Atomic manifest replacement
    gives a consistent read; a second read after leasing proves the input
    names still exist. An appended tail is safe, replaced inputs need a retry.
    """
    if not path_exists(directory + "/manifest.bin"):
        return CompactionCapture(None, False)
    return _lease_compaction_inputs(
        directory, dimension, _read_capture_manifest(directory, dimension),
        pins, source_lock=source_lock^, automatic=automatic,
    )


def _read_capture_manifest(directory: String, dimension: Int) raises -> Manifest:
    # load_manifest also stats referenced files, which may already be retired.
    var manifest = decode_manifest_bytes(read_manifest_bytes(directory), dimension)
    _validate_manifest_names(manifest, True)
    return manifest^


def _lease_compaction_inputs(
    directory: String,
    dimension: Int,
    var manifest: Manifest,
    pins: ArcPointer[GenerationPinRegistry],
    *,
    var source_lock: Optional[ArcPointer[CollectionLock]] = None,
    automatic: Bool = False,
) raises -> CompactionCapture:
    var has_work = len(manifest.segments) > 1 and (
        not automatic or CompactionPolicy(4).should_compact(manifest)
    )
    if has_work and manifest.generation == UInt64.MAX:
        raise Error("manifest generation exhausted")
    var inputs = CompactionInputs(manifest^)
    var pinned = False
    try:
        pins[].pin_manifest(inputs.manifest)
        pinned = True
        if has_work:
            _capture_catalog(directory, dimension, inputs)
            if automatic and inputs.catalog:
                var selected = select_point_merge_range(directory, inputs.manifest)
                inputs.first = selected[0]
                inputs.limit = selected[1]
    except error:
        if pinned:
            pins[].unpin(inputs.manifest.generation)
        var current = _read_capture_manifest(directory, dimension)
        if not _contains_inputs(inputs.manifest, current):
            return CompactionCapture(None, True)
        # Still-authoritative missing/corrupt files are never a benign race.
        raise error^
    var current: Manifest
    try:
        current = _read_capture_manifest(directory, dimension)
    except error:
        pins[].unpin(inputs.manifest.generation)
        raise error^
    if not _contains_inputs(inputs.manifest, current):
        # Even a successful flock can refer to an already-unlinked inode.
        # A manifest read after all shared leases proves names still belong
        # to this authority. Later retirement cannot unlink the leased files.
        pins[].unpin(inputs.manifest.generation)
        return CompactionCapture(None, True)
    if not has_work:
        # A no-op still checks authority; a missing single segment is an error.
        pins[].unpin(inputs.manifest.generation)
        return CompactionCapture(None, False)
    inputs.source_lock = source_lock^
    return CompactionCapture(Optional(inputs^), False)


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
        retired[].enqueue(compaction_input_paths(directory, inputs))
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
    var inputs = CompactionInputs(manifest^)
    _capture_catalog(directory, dimension, inputs)
    return Optional(inputs^)


def _capture_catalog(
    directory: String, dimension: Int, mut inputs: CompactionInputs
) raises:
    if is_point_checkpoint(directory, inputs.manifest):
        var identity = load_field_catalog(directory)
        if (
            identity.format_version != 2
            or identity.field_at(0).dimension != dimension
        ):
            raise Error("point compaction requires a matching field catalog")
        inputs.catalog = Optional(ArcPointer(identity^))


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
    if not _contains_inputs(captured, current):
        return None
    if current.generation == UInt64.MAX:
        raise Error("manifest generation exhausted")
    var descriptors = List[SegmentDescriptor]()
    for index in range(inputs.first):
        descriptors.append(current.segments[index].clone())
    var level = 1 if inputs.first == 0 else 0
    var minimum = UInt64(0) if inputs.first == 0 else captured.segments[inputs.first].min_sequence
    var maximum = captured.segments[inputs.limit - 1].max_sequence
    if output.sparse_name.byte_length() == 0:
        descriptors.append(
            SegmentDescriptor(level, minimum, maximum, output.checksum, output.segment_name)
        )
    else:
        descriptors.append(
            SegmentDescriptor.with_sparse(
                level, minimum, maximum, output.checksum, output.segment_name,
                output.sparse_checksum, output.sparse_name,
            )
        )
    for index in range(inputs.limit, len(current.segments)):
        if current.segments[index].min_sequence <= maximum:
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
    directory: String, inputs: CompactionInputs
) -> List[String]:
    """Only the selected files are retired; untouched prefix/suffix stay live."""
    ref manifest = inputs.manifest
    var paths = List[String]()
    for index in range(inputs.first, inputs.limit):
        paths.append(directory + "/" + manifest.segments[index].name)
        if manifest.segments[index].sparse_name.byte_length() > 0:
            paths.append(directory + "/" + manifest.segments[index].sparse_name)
    return paths^


def _contains_inputs(captured: Manifest, current: Manifest) -> Bool:
    if len(current.segments) < len(captured.segments):
        return False
    for index in range(len(captured.segments)):
        if not _same_segment(captured.segments[index], current.segments[index]):
            return False
    return True


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
    var merge = PointMerge(
        directory, inputs.manifest, inputs.catalog.value()[],
        first=inputs.first, limit=inputs.limit,
    )
    var name = _claim_output(
        directory, _SEGMENT_OUTPUT_PREFIX, inputs.manifest.generation + 1
    )
    var checksum: UInt32
    try:
        checksum = merge.write_segment(directory + "/" + name)
        sync_directory(directory)
    except error:
        try:
            remove_file_if_exists(directory + "/" + name)
        except:
            pass
        raise error^
    return CompactionOutput(name, checksum, "", 0)
