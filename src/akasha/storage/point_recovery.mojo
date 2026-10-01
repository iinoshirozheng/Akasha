from akasha.document.point_state import PointState
from akasha.document.vector_schema import FieldCatalog
from akasha.storage.filesystem import path_exists, read_file_bytes
from akasha.storage.manifest import Manifest, load_manifest
from akasha.storage.point_migration import (
    PointRecovery,
    preflight_migrating_points,
)
from akasha.storage.point_segment import decode_point_segment
from akasha.storage.point_table import PointTable
from akasha.storage.point_wal import FieldWalReader
from akasha.storage.sparse_store import preflight_sparse_wal
from std.collections import Dict
from std.memory import ArcPointer


def preflight_point_authority(
    path: String, var catalog: ArcPointer[FieldCatalog]
) raises -> PointRecovery:
    """Read committed point checkpoints and bounded WAL without repairing.

    Before the first point checkpoint, reuse the legacy cutover path. The first
    v4 checkpoint is a complete base, replacing the legacy segment set; later
    v4 deltas contain complete point states and can be merged independently.
    The caller must validate the committed catalog and hold collection exclusion.
    """
    if not path_exists(path + "/manifest.bin"):
        return preflight_migrating_points(path, catalog^)
    var manifest = load_manifest(path, catalog[].field_at(0).dimension)
    if not is_point_checkpoint(path, manifest):
        return preflight_migrating_points(path, catalog^)

    var points = load_point_checkpoint(path, manifest, catalog.copy())
    var sparse = preflight_sparse_wal(path + "/sparse.wal")
    for index in range(len(sparse.records)):
        if sparse.records[index].sequence > catalog[].legacy_cutover_sequence:
            raise Error("legacy sparse mutation follows field cutover")
    var reader = FieldWalReader(path + "/wal.bin", catalog.copy())
    while True:
        var next = reader.read_next()
        if not next:
            break
        if not next.value().is_legacy():
            points.replay(next.value().point_batch())
    return PointRecovery(
        Optional(points^),
        Optional(sparse^),
        manifest.generation,
        manifest.last_sequence,
        reader.valid_length,
        reader.source_length,
        True,
    )


def is_point_checkpoint(path: String, manifest: Manifest) raises -> Bool:
    """Select the versioned segment reader using only a bounded header read."""
    var prefix: List[UInt8]
    with open(path + "/" + manifest.segments[0].name, "r") as file:
        prefix = file.read_bytes(8)
    if len(prefix) < 8:
        raise Error("truncated checkpoint segment header")
    return (Int(prefix[4]) | (Int(prefix[5]) << 8)) == 4


def load_point_checkpoint(
    path: String, manifest: Manifest, var catalog: ArcPointer[FieldCatalog]
) raises -> PointTable:
    """Merge exactly the captured manifest; never read or modify the WAL."""
    if (
        catalog[].format_version != 2
        or catalog[].field_at(0).dimension != manifest.dimension
    ):
        raise Error("point checkpoint catalog does not match manifest")
    var states = List[PointState]()
    var ordinals = Dict[Int, Int]()
    for index in range(len(manifest.segments)):
        ref descriptor = manifest.segments[index]
        if (
            descriptor.sparse_name.byte_length() != 0
            or descriptor.sparse_checksum != 0
        ):
            raise Error("point checkpoints cannot carry legacy sparse segments")
        var bytes = read_file_bytes(path + "/" + descriptor.name)
        var segment = decode_point_segment(bytes, catalog[])
        if (
            segment.min_sequence != descriptor.min_sequence
            or segment.last_sequence != descriptor.max_sequence
            or segment.checksum != descriptor.checksum
            or (descriptor.level == 0 and segment.kind != 2)
            or (descriptor.level > 0 and segment.kind != 1)
        ):
            raise Error("point segment does not match committed manifest")
        for point_index in range(len(segment.points)):
            ref point = segment.points[point_index]
            var ordinal = ordinals.get(point.id, -1)
            if ordinal >= 0:
                if point.sequence <= states[ordinal].sequence:
                    raise Error("point checkpoint versions do not increase")
                states[ordinal] = point.copy()
            else:
                ordinals[point.id] = len(states)
                states.append(point.copy())
    return PointTable(catalog^, manifest.last_sequence, states^)
