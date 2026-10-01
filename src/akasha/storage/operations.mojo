from akasha.document.vector_schema import FieldCatalog
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.index.hnsw_rebuild import restore_hnsw_overlay
from akasha.storage.field_catalog import (
    load_field_catalog,
    publish_field_catalog,
)
from akasha.storage.point_recovery import (
    is_point_checkpoint,
    load_point_checkpoint,
)
from akasha.storage.immutable_copy import copy_verified_immutable
from akasha.storage.collection_config import (
    collection_config_exists,
    publish_collection_config,
)
from akasha.common.config import CollectionConfig
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    sync_directory,
)
from akasha.storage.manifest import (
    load_manifest,
    hnsw_base_sequence,
    Manifest,
    publish_manifest,
)
from akasha.storage.hnsw_store import try_open_compatible_hnsw_snapshot_view
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
from std.memory import ArcPointer


comptime COPY_BUFFER_BYTES = 1 << 20
"""Bytes each backup or restore file copy streams through at a time."""

comptime _DENSE_MAGIC = "AKSG"
comptime _SPARSE_MAGIC = "AKPR"
comptime _HNSW_MAGIC = "AKHG"


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

    The complete captured manifest, including its immutable derived sidecar,
    is protected by the caller's generation lease until the copy completes.
    """

    var manifest: Manifest
    var config: Optional[CollectionConfig]
    var report: StorageInspection
    var catalog: Optional[ArcPointer[FieldCatalog]]
    var _source_lock: Optional[ArcPointer[CollectionLock]]

    def __init__(
        out self,
        var manifest: Manifest,
        var config: Optional[CollectionConfig],
        live_points: Int,
        *,
        var source_lock: Optional[ArcPointer[CollectionLock]] = None,
        var catalog: Optional[ArcPointer[FieldCatalog]] = None,
    ) raises:
        if catalog:
            if (
                catalog.value()[].format_version != 2
                or not config
                or catalog.value()[].field_at(0).hnsw.value() != config.value()
            ):
                raise Error("checkpoint copy catalog and config mismatch")
        var report = _report(manifest, live_points, config)
        self.manifest = manifest^
        self.config = config^
        self.catalog = catalog^
        self.report = report^
        self._source_lock = source_lock^


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
        manifest^,
        _stored_config(backup, expected_dimension),
        live_points,
        catalog=_stored_point_catalog(backup),
    )
    _publish_checkpoint(backup, target, checkpoint, COPY_BUFFER_BYTES)
    target_lock.close()
    return checkpoint.report.copy()


def _checked_live_points(
    directory: String, manifest: Manifest, expected_dimension: Int
) raises -> Int:
    var memtable = MemTable(expected_dimension)
    if is_point_checkpoint(directory, manifest):
        var catalog = _stored_point_catalog(directory)
        if not catalog:
            raise Error("point checkpoint requires a field catalog")
        var points = load_point_checkpoint(directory, manifest, catalog.take())
        memtable = points.read_projection()
    else:
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
                    descriptor.level > 0
                    and sparse.kind != SPARSE_SEGMENT_KIND_BASE
                ):
                    raise Error("manifest and sparse segment level mismatch")
    if manifest.hnsw_name:
        var dense_count = 0
        for ordinal in memtable.live_ordinals():
            if memtable.entry_ref_at(ordinal).has_dense():
                dense_count += 1
        var stored_config = _stored_config(directory, expected_dimension)
        var config = stored_config.value().copy() if stored_config else CollectionConfig.defaults(
            expected_dimension
        )
        if manifest.hnsw_config_fingerprint.value() != config.fingerprint() or (
            manifest.format_version != 5
            and manifest.hnsw_point_count.value() != UInt64(dense_count)
        ):
            raise Error(
                "manifest HNSW identity does not match authoritative data"
            )
        var loaded = try_open_compatible_hnsw_snapshot_view(
            directory + "/" + manifest.hnsw_name.value(),
            config,
            hnsw_base_sequence(manifest),
            manifest.hnsw_checksum.value(),
            manifest.hnsw_point_count.value(),
        )
        if not loaded.hit():
            raise Error("manifest HNSW sidecar is missing or stale")
        if manifest.format_version == 5:
            var index = SegmentedHnsw.from_mapped(loaded.take_view())
            _ = restore_hnsw_overlay(
                index, memtable, hnsw_base_sequence(manifest)
            )
            index.close()
            return memtable.live_count()
        for slot_index in range(loaded.view.slot_count()):
            var slot = UInt32(slot_index)
            if not loaded.view.is_current(slot):
                continue
            var ordinal = memtable.ordinal_for(loaded.view.id_at(slot))
            if (
                ordinal < 0
                or not memtable.is_live_at(ordinal)
                or not memtable.entry_ref_at(ordinal).has_dense()
            ):
                raise Error("HNSW sidecar IDs do not match authoritative data")
        loaded.view.close()
    return memtable.live_count()


def _stored_config(
    directory: String, expected_dimension: Int
) raises -> Optional[CollectionConfig]:
    if not collection_config_exists(directory):
        return None
    var catalog = load_field_catalog(directory)
    var config = catalog.field_at(0).hnsw.value().copy()
    if config.dimension != expected_dimension:
        raise Error("collection config dimension mismatch")
    return config^


def _stored_point_catalog(
    directory: String,
) raises -> Optional[ArcPointer[FieldCatalog]]:
    if not collection_config_exists(directory):
        return None
    var catalog = load_field_catalog(directory)
    if catalog.format_version == 1:
        return None
    return Optional(ArcPointer(catalog^))


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
    if checkpoint.catalog:
        if not is_point_checkpoint(source, checkpoint.manifest):
            raise Error(
                "field-aware backup requires a complete point checkpoint"
            )
        publish_field_catalog(target, checkpoint.catalog.value()[], [])
    elif checkpoint.config:
        # The immutable identity must reach the backup before its manifest
        # commit point. Publication is idempotent for a retry with the same
        # identity and rejects a stale target with a different identity.
        publish_collection_config(target, checkpoint.config.value())
    elif collection_config_exists(target):
        raise Error("backup target identity is absent from legacy source")
    var buffer = List[UInt8](length=buffer_bytes, fill=0)
    for index in range(len(checkpoint.manifest.segments)):
        ref descriptor = checkpoint.manifest.segments[index]
        copy_verified_immutable(
            source,
            target,
            descriptor.name,
            _DENSE_MAGIC,
            descriptor.checksum,
            buffer,
        )
        if descriptor.sparse_name.byte_length() > 0:
            copy_verified_immutable(
                source,
                target,
                descriptor.sparse_name,
                _SPARSE_MAGIC,
                descriptor.sparse_checksum,
                buffer,
            )
    if checkpoint.manifest.hnsw_name:
        copy_verified_immutable(
            source,
            target,
            checkpoint.manifest.hnsw_name.value(),
            _HNSW_MAGIC,
            checkpoint.manifest.hnsw_checksum.value(),
            buffer,
            hnsw_identity=Optional(
                (
                    hnsw_base_sequence(checkpoint.manifest),
                    checkpoint.manifest.hnsw_config_fingerprint.value(),
                    checkpoint.manifest.hnsw_point_count.value(),
                )
            ),
        )
    # Every renamed file is durable before the manifest can name it.
    sync_directory(target)
    publish_manifest(target, checkpoint.manifest)
