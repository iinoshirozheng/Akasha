from akasha.storage.checksum import CRC32_INITIAL, crc32_update
from akasha.storage.collection_config import (
    collection_config_exists,
    load_collection_config,
    publish_collection_config,
)
from akasha.common.config import CollectionConfig
from akasha.storage.filesystem import (
    atomic_replace,
    ensure_directory,
    path_exists,
    sync_directory,
    sync_file,
)
from akasha.storage.manifest import (
    load_manifest,
    Manifest,
    publish_manifest,
    SegmentDescriptor,
)
from akasha.storage.lock import CollectionLock
from akasha.storage.memtable import MemTable
from akasha.storage.segment import (
    read_segment,
    SEGMENT_KIND_BASE,
    SEGMENT_KIND_DELTA,
)
from akasha.storage.sparse_store import (
    read_sparse_segment,
    SPARSE_SEGMENT_KIND_BASE,
    SPARSE_SEGMENT_KIND_DELTA,
)
from std.os import SEEK_END


comptime COPY_BUFFER_BYTES = 1 << 20
"""Bytes each backup or restore file copy streams through at a time."""

comptime _DENSE_MAGIC = "AKSG"
comptime _SPARSE_MAGIC = "AKPR"


struct StorageInspection(Copyable, Movable):
    var dimension: Int
    var format_version: Int
    var generation: UInt64
    var last_sequence: UInt64
    var segment_count: Int
    var live_points: Int
    var valid: Bool
    var config_fingerprint: UInt64
    var segment_names: List[String]
    var sparse_names: List[String]

    def __init__(
        out self,
        dimension: Int,
        format_version: Int,
        generation: UInt64,
        last_sequence: UInt64,
        segment_count: Int,
        live_points: Int,
        config_fingerprint: UInt64,
        var segment_names: List[String],
        var sparse_names: List[String],
    ):
        self.dimension = dimension
        self.format_version = format_version
        self.generation = generation
        self.last_sequence = last_sequence
        self.segment_count = segment_count
        self.live_points = live_points
        self.valid = True
        self.config_fingerprint = config_fingerprint
        self.segment_names = segment_names^
        self.sparse_names = sparse_names^


struct CheckpointCopy(Movable):
    """One committed checkpoint to copy and the report describing the copy.

    The manifest omits the derived HNSW sidecar: checkpoints replace that file
    outside generation leases, so a copy rebuilds its graph when opened.
    """

    var manifest: Manifest
    var config: Optional[CollectionConfig]
    var report: StorageInspection

    def __init__(
        out self,
        var manifest: Manifest,
        var config: Optional[CollectionConfig],
        live_points: Int,
    ) raises:
        var authoritative = _without_derived_files(manifest^)
        var report = _report(authoritative, live_points, config)
        self.manifest = authoritative^
        self.config = config^
        self.report = report^


def inspect_storage(
    directory: String, expected_dimension: Int
) raises -> StorageInspection:
    """Strictly decode the manifest and every referenced immutable file."""
    var manifest = load_manifest(directory, expected_dimension)
    var live_points = _checked_live_points(
        directory, manifest, expected_dimension
    )
    return _report(
        manifest, live_points, _stored_config(directory, expected_dimension)
    )


def copy_checkpoint(
    source: String,
    target: String,
    checkpoint: CheckpointCopy,
    buffer_bytes: Int = COPY_BUFFER_BYTES,
) raises:
    """Publish a captured checkpoint into an empty target, manifest last.

    The caller keeps the checkpoint's files from being reclaimed until this
    returns; each file must match its descriptor before it is renamed.
    """
    if buffer_bytes <= 0:
        raise Error("copy buffer size must be positive")
    var target_lock = _lock_empty_target(source, target)
    _publish_checkpoint(source, target, checkpoint, buffer_bytes)
    target_lock.close()


def restore_storage(
    backup: String, target: String, expected_dimension: Int
) raises -> StorageInspection:
    """Restore only a fully validated committed backup generation."""
    var target_lock = _lock_empty_target(backup, target)
    var manifest = load_manifest(backup, expected_dimension)
    var live_points = _checked_live_points(backup, manifest, expected_dimension)
    var checkpoint = CheckpointCopy(
        manifest^, _stored_config(backup, expected_dimension), live_points
    )
    _publish_checkpoint(backup, target, checkpoint, COPY_BUFFER_BYTES)
    target_lock.close()
    return checkpoint.report.copy()


def _checked_live_points(
    directory: String, manifest: Manifest, expected_dimension: Int
) raises -> Int:
    var memtable = MemTable(expected_dimension)
    for index in range(len(manifest.segments)):
        var descriptor = manifest.segments[index].clone()
        var dense = read_segment(
            directory + "/" + descriptor.name, expected_dimension
        )
        if (
            dense.checksum != descriptor.checksum
            or dense.min_sequence != descriptor.min_sequence
            or dense.last_sequence != descriptor.max_sequence
        ):
            raise Error("manifest and dense segment metadata mismatch")
        if (descriptor.level == 0 and dense.kind != SEGMENT_KIND_DELTA) or (
            descriptor.level > 0 and dense.kind != SEGMENT_KIND_BASE
        ):
            raise Error("manifest and dense segment level mismatch")
        memtable.apply_recovered_entries(dense.entries)

        if descriptor.sparse_name.byte_length() > 0:
            var sparse = read_sparse_segment(
                directory + "/" + descriptor.sparse_name
            )
            if (
                sparse.checksum != descriptor.sparse_checksum
                or sparse.min_sequence != descriptor.min_sequence
                or sparse.last_sequence != descriptor.max_sequence
            ):
                raise Error("manifest and sparse segment metadata mismatch")
            if (
                descriptor.level == 0
                and sparse.kind != SPARSE_SEGMENT_KIND_DELTA
            ) or (
                descriptor.level > 0 and sparse.kind != SPARSE_SEGMENT_KIND_BASE
            ):
                raise Error("manifest and sparse segment level mismatch")
    return memtable.live_count()


def _stored_config(
    directory: String, expected_dimension: Int
) raises -> Optional[CollectionConfig]:
    if not collection_config_exists(directory):
        return None
    var config = load_collection_config(directory)
    if config.dimension != expected_dimension:
        raise Error("collection config dimension mismatch")
    return config^


def _report(
    manifest: Manifest, live_points: Int, config: Optional[CollectionConfig]
) -> StorageInspection:
    var names = List[String]()
    var sparse_names = List[String]()
    for index in range(len(manifest.segments)):
        names.append(manifest.segments[index].name)
        if manifest.segments[index].sparse_name.byte_length() > 0:
            sparse_names.append(manifest.segments[index].sparse_name)
    var fingerprint = (
        config.value()
        .fingerprint() if config else CollectionConfig.defaults(
            manifest.dimension
        )
        .fingerprint()
    )
    return StorageInspection(
        manifest.dimension,
        manifest.format_version,
        manifest.generation,
        manifest.last_sequence,
        len(manifest.segments),
        live_points,
        fingerprint,
        names^,
        sparse_names^,
    )


def _without_derived_files(var manifest: Manifest) raises -> Manifest:
    if not manifest.hnsw_name:
        return manifest^
    var segments = List[SegmentDescriptor](capacity=len(manifest.segments))
    for index in range(len(manifest.segments)):
        segments.append(manifest.segments[index].clone())
    return Manifest.with_segments(
        manifest.dimension,
        manifest.generation,
        manifest.last_sequence,
        segments^,
    )


def _lock_empty_target(source: String, target: String) raises -> CollectionLock:
    if source == target:
        raise Error("backup source and target must differ")
    ensure_directory(target)
    # Serialize the target preflight, immutable copies, and manifest commit
    # with the same lock used by collection writers. Without this boundary a
    # writer could append an acknowledged WAL record after the checks below
    # and have it hidden or mixed by the restored snapshot sequence.
    var target_lock = CollectionLock.acquire(target + "/collection.lock")
    if path_exists(target + "/manifest.bin"):
        raise Error("backup target already contains a committed manifest")
    if path_exists(target + "/wal.bin") or path_exists(target + "/sparse.wal"):
        raise Error("backup target already contains authoritative WAL state")
    return target_lock^


def _publish_checkpoint(
    source: String,
    target: String,
    checkpoint: CheckpointCopy,
    buffer_bytes: Int,
) raises:
    if checkpoint.config:
        # The immutable identity must reach the backup before its manifest
        # commit point. Publication is idempotent for a retry with the same
        # identity and rejects a stale target with a different identity.
        publish_collection_config(target, checkpoint.config.value())
    elif collection_config_exists(target):
        raise Error("backup target identity is absent from legacy source")
    var buffer = List[UInt8](length=buffer_bytes, fill=0)
    for index in range(len(checkpoint.manifest.segments)):
        ref descriptor = checkpoint.manifest.segments[index]
        _copy_verified(
            source,
            target,
            descriptor.name,
            _DENSE_MAGIC,
            descriptor.checksum,
            buffer,
        )
        if descriptor.sparse_name.byte_length() > 0:
            _copy_verified(
                source,
                target,
                descriptor.sparse_name,
                _SPARSE_MAGIC,
                descriptor.sparse_checksum,
                buffer,
            )
    # Every renamed file is durable before the manifest can name it.
    sync_directory(target)
    publish_manifest(target, checkpoint.manifest)


def _copy_verified(
    source: String,
    target: String,
    name: String,
    magic: StaticString,
    checksum: UInt32,
    mut buffer: List[UInt8],
) raises:
    """Stream one immutable file into place through ``buffer``.

    Both segment formats start with a four-byte magic and end with the
    little-endian CRC-32 of the bytes between them.
    """
    var temporary = target + "/" + name + ".tmp"
    with open(source + "/" + name, "r") as input:
        var size = Int(input.seek(0, SEEK_END))
        _ = input.seek(0)
        if size < 8:
            raise Error("truncated immutable file: " + name)
        var tail_start = size - 4
        var register = CRC32_INITIAL
        var stored = UInt32(0)
        var offset = 0
        with open(temporary, "w") as output:
            while True:
                var count = input.read(Span(buffer))
                if count == 0:
                    break
                var end = offset + count
                if end > size:
                    raise Error("immutable file grew while copied: " + name)
                var bytes = Span(buffer)[:count]
                for position in range(offset, min(end, 4)):
                    if bytes[position - offset] != magic.as_bytes()[position]:
                        raise Error("immutable file magic mismatch: " + name)
                var body_start = max(offset, 4)
                var body_end = min(end, tail_start)
                if body_start < body_end:
                    register = crc32_update(
                        register,
                        bytes[body_start - offset : body_end - offset],
                    )
                for position in range(max(offset, tail_start), end):
                    stored |= UInt32(bytes[position - offset]) << UInt32(
                        8 * (position - tail_start)
                    )
                output.write_all(bytes)
                offset = end
            if offset != size:
                raise Error("immutable file shrank while copied: " + name)
            if stored != checksum or ~register != checksum:
                raise Error("immutable file checksum mismatch: " + name)
            sync_file(output)
    atomic_replace(temporary, target + "/" + name)
