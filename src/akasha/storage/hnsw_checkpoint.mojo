from akasha.index.hnsw import HnswIndex
from akasha.storage.filesystem import (
    create_file_exclusive,
    remove_file_if_exists,
    sync_directory,
)
from akasha.storage.hnsw_store import HnswSnapshotInfo, write_hnsw_snapshot
from akasha.storage.immutable_copy import copy_verified_immutable
from akasha.storage.manifest import Manifest


struct HnswCheckpoint(Movable):
    var name: String
    var info: HnswSnapshotInfo

    def __init__(out self, var name: String, var info: HnswSnapshotInfo):
        self.name = name^
        self.info = info^


def write_hnsw_checkpoint(
    directory: String, index: HnswIndex, sequence: UInt64, generation: UInt64
) raises -> HnswCheckpoint:
    """Durably write a fresh owned path; the manifest remains the commit point.

    Like full-compaction outputs, exclusive path creation protects both pinned
    old files and outputs whose manifest publication returned an uncertain error.
    """
    if generation == 0:
        raise Error("HNSW checkpoint generation must be positive")
    for claim in range(1_024):
        var name = (
            "hnsw-"
            + String(sequence)
            + "-"
            + String(generation)
            + "-"
            + String(claim)
            + ".bin"
        )
        if not create_file_exclusive(directory + "/" + name):
            continue
        try:
            var info = write_hnsw_snapshot(
                directory + "/" + name, index, sequence
            )
            sync_directory(directory)
            return HnswCheckpoint(name^, info^)
        except error:
            remove_file_if_exists(directory + "/" + name)
            sync_directory(directory)
            raise error^
    raise Error("no free HNSW checkpoint output name")


def migrate_hnsw_base_name(
    directory: String, manifest: Manifest, generation: UInt64
) raises -> String:
    """Copy a validated v3 base into an exclusive canonical v5 job name.

    Its graph bytes/sequence are unchanged. The caller publishes the new name
    atomically with authority, then retires the old name through file leases.
    """
    if (
        manifest.format_version != 3
        or not manifest.hnsw_name
        or generation == 0
    ):
        raise Error("legacy HNSW name migration requires a committed v3 base")
    var buffer = List[UInt8](length=1 << 20, fill=0)
    for claim in range(1024):
        var name = String(
            "hnsw-", manifest.last_sequence, "-", generation, "-", claim, ".bin"
        )
        if not create_file_exclusive(directory + "/" + name):
            continue
        try:
            copy_verified_immutable(
                directory,
                directory,
                manifest.hnsw_name.value(),
                "AKHG",
                manifest.hnsw_checksum.value(),
                buffer,
                hnsw_identity=Optional(
                    (
                        manifest.last_sequence,
                        manifest.hnsw_config_fingerprint.value(),
                        manifest.hnsw_point_count.value(),
                    )
                ),
                target_name=name,
            )
            sync_directory(directory)
            return name^
        except error:
            remove_file_if_exists(directory + "/" + name + ".tmp")
            remove_file_if_exists(directory + "/" + name)
            sync_directory(directory)
            raise error^
    raise Error("no free HNSW migration output name")
