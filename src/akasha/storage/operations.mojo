from akasha.storage.collection_config import (
    collection_config_exists,
    load_collection_config,
    publish_collection_config,
)
from akasha.storage.filesystem import (
    atomic_replace,
    ensure_directory,
    path_exists,
    read_file_bytes,
    sync_directory,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest, publish_manifest
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


struct StorageInspection(Movable):
    var dimension: Int
    var format_version: Int
    var generation: UInt64
    var last_sequence: UInt64
    var segment_count: Int
    var live_points: Int
    var valid: Bool
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
        self.segment_names = segment_names^
        self.sparse_names = sparse_names^


def inspect_storage(
    directory: String, expected_dimension: Int
) raises -> StorageInspection:
    """Strictly decode the manifest and every referenced immutable file."""
    var manifest = load_manifest(directory, expected_dimension)
    var memtable = MemTable(expected_dimension)
    var names = List[String]()
    var sparse_names = List[String]()
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
        if (
            descriptor.level == 0 and dense.kind != SEGMENT_KIND_DELTA
        ) or (
            descriptor.level > 0 and dense.kind != SEGMENT_KIND_BASE
        ):
            raise Error("manifest and dense segment level mismatch")
        memtable.apply_recovered_entries(dense.entries)
        names.append(descriptor.name)

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
            sparse_names.append(descriptor.sparse_name)

    var live = memtable.live_entries()
    return StorageInspection(
        manifest.dimension,
        manifest.format_version,
        manifest.generation,
        manifest.last_sequence,
        len(manifest.segments),
        len(live),
        names^,
        sparse_names^,
    )


def backup_storage(
    source: String, target: String, expected_dimension: Int
) raises -> StorageInspection:
    """Copy one validated committed generation and publish its manifest last."""
    if source == target:
        raise Error("backup source and target must differ")
    ensure_directory(target)
    if path_exists(target + "/manifest.bin"):
        raise Error("backup target already contains a committed manifest")
    var report = inspect_storage(source, expected_dimension)
    var manifest = load_manifest(source, expected_dimension)
    if collection_config_exists(source):
        var config = load_collection_config(source)
        if config.dimension != expected_dimension:
            raise Error("collection config dimension mismatch")
        # The immutable identity must reach the backup before its manifest
        # commit point. Publication is idempotent for a retry with the same
        # identity and rejects a stale target with a different identity.
        publish_collection_config(target, config)
    elif collection_config_exists(target):
        raise Error("backup target identity is absent from legacy source")
    for name in report.segment_names:
        _copy_immutable(source, target, name)
    for name in report.sparse_names:
        _copy_immutable(source, target, name)
    publish_manifest(target, manifest^)
    return report^


def restore_storage(
    backup: String, target: String, expected_dimension: Int
) raises -> StorageInspection:
    """Restore only a fully validated committed backup generation."""
    return backup_storage(backup, target, expected_dimension)


def _copy_immutable(source: String, target: String, name: String) raises:
    var bytes = read_file_bytes(source + "/" + name)
    var temporary = target + "/" + name + ".tmp"
    write_file_sync(temporary, bytes)
    atomic_replace(temporary, target + "/" + name)
    sync_directory(target)
