from akasha.common.config import CollectionConfig
from akasha.document.point_state import PointMutation, PointState
from akasha.document.vector_value import VectorValue
from akasha.query.field_search import FieldSearchResult, search_point_field
from akasha.query.filter_ast import FilterExpression
from akasha.document.vector_schema import (
    FieldCatalog,
    VectorFieldSpec,
    MAX_FIELD_CATALOG_BYTES,
)
from akasha.storage.compaction import LEVEL_ZERO_SEGMENT_LIMIT
from akasha.storage.field_catalog import (
    decode_field_catalog_bytes,
    encode_field_catalog,
    publish_field_catalog,
)
from akasha.storage.filesystem import (
    create_file_exclusive,
    ensure_durable_directory,
    path_exists,
    read_file_bytes_bounded,
    remove_file_if_exists,
    sync_directory,
    write_file_sync,
)
from akasha.storage.hnsw_store import (
    try_open_compatible_hnsw_snapshot_view,
    try_read_compatible_hnsw_snapshot_owned,
)
from akasha.storage.hnsw_checkpoint import (
    HnswCheckpoint,
    migrate_hnsw_base_name,
)
from akasha.storage.legacy_recovery import preflight_legacy_authority
from akasha.storage.lock import CollectionLock
from akasha.storage.file_leases import reclaim_unreferenced_job_files
from akasha.storage.manifest import (
    Manifest,
    SegmentDescriptor,
    load_manifest,
    hnsw_base_sequence,
    publish_manifest,
)
from akasha.storage.point_migration import (
    PointRecovery,
    point_table_from_legacy,
)
from akasha.storage.point_recovery import preflight_point_authority
from akasha.storage.point_segment import encode_point_segment
from akasha.storage.point_table import PointCommit, PointTable
from akasha.storage.retired_files import RetiredFileQueue
from akasha.storage.sparse_store import (
    repair_sparse_wal_tail,
    rotate_sparse_wal,
)
from akasha.storage.wal import repair_wal_tail, rotate_wal
from akasha.storage.checksum import BorrowedBinaryReader
from std.memory import ArcPointer


@fieldwise_init
struct PointStore(Movable):
    """Field-aware durable authority; operations require caller serialization.

    Owns the collection file lock, immutable catalog and authoritative point map.
    Query/index facades consume its immutable states. The first checkpoint after
    migration is a complete point base; subsequent checkpoints append deltas.
    """

    var _path: String
    var _catalog: ArcPointer[FieldCatalog]
    var _table: PointTable
    var _lock: Optional[ArcPointer[CollectionLock]]
    var _manifest: Optional[Manifest]
    var _point_checkpoint: Bool
    var _retired: RetiredFileQueue
    var _io_failed: Bool
    var _hnsw_reference_valid: Bool

    @staticmethod
    def open(
        path: String, var fields: List[VectorFieldSpec]
    ) raises -> PointStore:
        var requested = FieldCatalog(1, 0, fields.copy())
        _ = ensure_durable_directory(path)
        var lock = CollectionLock.acquire(path + "/collection.lock")
        var expected = List[UInt8]()
        var existing = Optional[FieldCatalog]()
        if path_exists(path + "/collection.bin"):
            expected = read_file_bytes_bounded(
                path + "/collection.bin", MAX_FIELD_CATALOG_BYTES
            )
            existing = Optional(decode_field_catalog_bytes(expected))
        var catalog: ArcPointer[FieldCatalog]
        var recovered: PointRecovery
        var needs_publication = (
            not existing or existing.value().format_version == 1
        )
        if not needs_publication:
            var matched = FieldCatalog(
                existing.value().schema_revision,
                existing.value().legacy_cutover_sequence,
                fields^,
            )
            if encode_field_catalog(matched) != expected:
                raise Error(
                    "requested vector fields differ from collection identity"
                )
            catalog = ArcPointer(existing.take())
            recovered = preflight_point_authority(path, catalog.copy())
        else:
            ref config = requested.field_at(0).hnsw.value()
            if existing:
                if existing.value().field_at(0).hnsw.value() != config:
                    raise Error(
                        "field migration cannot change default configuration"
                    )
            elif (
                path_exists(path + "/wal.bin")
                or path_exists(path + "/manifest.bin")
            ) and config != CollectionConfig.defaults(config.dimension):
                raise Error(
                    "legacy data without identity requires default"
                    " configuration"
                )
            var legacy = preflight_legacy_authority(path, config.dimension)
            catalog = ArcPointer(FieldCatalog(1, legacy.last_sequence, fields^))
            var points = point_table_from_legacy(
                legacy.memtable.value(), catalog.copy()
            )
            recovered = PointRecovery(
                Optional(points^),
                Optional(legacy.sparse_wal.take()),
                legacy.generation,
                legacy.snapshot_sequence,
                legacy.wal_valid_length,
                legacy.wal_source_length,
                False,
            )

        var manifest = Optional[Manifest]()
        var hnsw_valid = False
        if path_exists(path + "/manifest.bin"):
            manifest = Optional(
                load_manifest(path, catalog[].field_at(0).dimension)
            )
            hnsw_valid = _validate_committed_graph(
                path, catalog[], manifest.value()
            )
        if needs_publication:
            publish_field_catalog(path, catalog[], expected)
        repair_wal_tail(
            path + "/wal.bin",
            recovered.wal_valid_length,
            recovered.wal_source_length,
        )
        repair_sparse_wal_tail(
            path + "/sparse.wal", recovered.sparse_wal.value()
        )
        reclaim_unreferenced_job_files(path, catalog[].field_at(0).dimension)
        if not path_exists(path + "/wal.bin"):
            write_file_sync(path + "/wal.bin", List[UInt8]())
            sync_directory(path)
        return PointStore(
            path.copy(),
            catalog^,
            recovered.points.take(),
            Optional(ArcPointer(lock^)),
            manifest^,
            recovered.point_checkpoint,
            RetiredFileQueue(),
            False,
            hnsw_valid,
        )

    def close(mut self) raises:
        self._lock = None

    def last_sequence(self) raises -> UInt64:
        self._ensure_open()
        return self._table.last_sequence()

    def get(self, id: Int) raises -> Optional[PointState]:
        self._ensure_open()
        return self._table.get(id)

    def apply_batch(
        mut self, mutations: List[PointMutation]
    ) raises -> PointCommit:
        self._ensure_writable()
        return self._table.append_batch(self._path + "/wal.bin", mutations)

    def flush(mut self, var hnsw: Optional[HnswCheckpoint] = None) raises:
        self._checkpoint(False, hnsw^)

    def search(
        self,
        name: String,
        query: VectorValue,
        k: Int,
        var expression: Optional[FilterExpression] = Optional[
            FilterExpression
        ](),
    ) raises -> List[FieldSearchResult]:
        self._ensure_open()
        var ordinal = self._catalog[].named_ordinal(name)
        if ordinal < 0:
            raise Error("unknown named vector field")
        return search_point_field(
            self._table.entry_view(),
            self._catalog[].field_at(ordinal),
            query,
            k,
            expression,
        )

    def compact(mut self) raises:
        self._checkpoint(True)

    def _checkpoint(
        mut self, compact: Bool, var hnsw: Optional[HnswCheckpoint] = None
    ) raises:
        self._ensure_writable()
        # A compaction may have rebased the committed prefix since the last
        # flush. The caller's writer exclusion protects this refresh/publication.
        if path_exists(self._path + "/manifest.bin"):
            self._manifest = Optional(
                load_manifest(self._path, self._catalog[].field_at(0).dimension)
            )
        var sequence = self._table.last_sequence()
        if hnsw:
            if (
                hnsw.value().info.sequence > sequence
                or hnsw.value().info.config_fingerprint
                != self._catalog[].field_at(0).hnsw.value().fingerprint()
            ):
                raise Error("point checkpoint HNSW identity mismatch")
        if self._manifest and self._manifest.value().last_sequence > sequence:
            raise Error("committed checkpoint exceeds accepted point state")
        var previous = UInt64(0)
        var generation = UInt64(1)
        if self._manifest:
            previous = self._manifest.value().last_sequence
            if self._manifest.value().generation == UInt64.MAX:
                raise Error("point checkpoint generation exhausted")
            generation = self._manifest.value().generation + 1
            if self._point_checkpoint and previous == sequence and not compact:
                if hnsw:
                    var descriptors = List[SegmentDescriptor]()
                    for index in range(len(self._manifest.value().segments)):
                        descriptors.append(
                            self._manifest.value().segments[index].clone()
                        )
                    var updated = Manifest.with_hnsw(
                        self._catalog[].field_at(0).dimension,
                        generation,
                        sequence,
                        descriptors^,
                        hnsw.value().name,
                        hnsw.value().info.checksum,
                        hnsw.value().info.config_fingerprint,
                        hnsw.value().info.live_point_count,
                        format_version=4 if hnsw.value().info.sequence
                        == sequence else 5,
                    )
                    var retired = List[String]()
                    if self._manifest.value().hnsw_name:
                        retired.append(
                            self._path
                            + "/"
                            + self._manifest.value().hnsw_name.value()
                        )
                    self._io_failed = True
                    publish_manifest(self._path, updated)
                    self._manifest = Optional(updated^)
                    self._hnsw_reference_valid = True
                    self._retired.retire_or_reclaim(self._path, retired)
                    self._io_failed = False
                return
        var full = compact or not self._point_checkpoint
        if (
            self._manifest
            and len(self._manifest.value().segments) >= LEVEL_ZERO_SEGMENT_LIMIT
        ):
            full = True
        var states = (
            self._table.live_points() if full else self._table.points_after(
                previous
            )
        )
        var minimum = UInt64(0) if full else previous + 1
        var kind = 1 if full else 2
        var bytes = encode_point_segment(
            kind, minimum, sequence, states, self._catalog[]
        )
        var checksum_reader = BorrowedBinaryReader(
            Span(bytes)[len(bytes) - 4 :]
        )
        var checksum = checksum_reader.read_u32()
        var descriptors = List[SegmentDescriptor]()
        var retired = List[String]()
        var migrated_hnsw_name = Optional[String]()
        if (
            not hnsw
            and self._hnsw_reference_valid
            and self._manifest
            and self._manifest.value().hnsw_name
            and self._manifest.value().format_version == 3
            and previous < sequence
        ):
            migrated_hnsw_name = Optional(
                migrate_hnsw_base_name(
                    self._path, self._manifest.value(), generation
                )
            )
        var retain_hnsw = (
            not hnsw
            and self._hnsw_reference_valid
            and self._manifest
            and self._manifest.value().hnsw_name
            and (
                self._manifest.value().format_version >= 4
                or self._manifest.value().last_sequence == sequence
                or Bool(migrated_hnsw_name)
            )
        )
        if self._manifest:
            for index in range(len(self._manifest.value().segments)):
                ref descriptor = self._manifest.value().segments[index]
                if full:
                    retired.append(self._path + "/" + descriptor.name)
                    if descriptor.sparse_name.byte_length() > 0:
                        retired.append(
                            self._path + "/" + descriptor.sparse_name
                        )
                else:
                    descriptors.append(descriptor.clone())
            if self._manifest.value().hnsw_name and (
                not retain_hnsw or Bool(migrated_hnsw_name)
            ):
                retired.append(
                    self._path + "/" + self._manifest.value().hnsw_name.value()
                )

        # No accepted in-memory write is lost if any later publication is
        # uncertain: keep the WAL and require reopen before another mutation.
        self._io_failed = True
        var name = _write_point_checkpoint(
            self._path, kind, sequence, generation, bytes
        )
        descriptors.append(
            SegmentDescriptor(
                1 if full else 0, minimum, sequence, checksum, name
            )
        )
        var manifest: Manifest
        if hnsw:
            manifest = Manifest.with_hnsw(
                self._catalog[].field_at(0).dimension,
                generation,
                sequence,
                descriptors^,
                hnsw.value().name,
                hnsw.value().info.checksum,
                hnsw.value().info.config_fingerprint,
                hnsw.value().info.live_point_count,
                format_version=4 if hnsw.value().info.sequence
                == sequence else 5,
            )
        elif retain_hnsw:
            ref old = self._manifest.value()
            manifest = Manifest.with_hnsw(
                self._catalog[].field_at(0).dimension,
                generation,
                sequence,
                descriptors^,
                migrated_hnsw_name.value() if migrated_hnsw_name else old.hnsw_name.value(),
                old.hnsw_checksum.value(),
                old.hnsw_config_fingerprint.value(),
                old.hnsw_point_count.value(),
                format_version=5 if old.format_version >= 4
                or Bool(migrated_hnsw_name) else 3,
            )
        else:
            manifest = Manifest.with_segments(
                self._catalog[].field_at(0).dimension,
                generation,
                sequence,
                descriptors^,
            )
        publish_manifest(self._path, manifest)
        self._manifest = Optional(manifest^)
        self._point_checkpoint = True
        self._hnsw_reference_valid = Bool(hnsw) or retain_hnsw
        rotate_wal(self._path)
        rotate_sparse_wal(self._path)
        self._retired.retire_or_reclaim(self._path, retired)
        self._io_failed = False

    def _ensure_open(self) raises:
        if not self._lock:
            raise Error("point store is closed")

    def _ensure_writable(self) raises:
        self._ensure_open()
        if self._io_failed or self._table._write_failed:
            raise Error("point store requires reopen after uncertain I/O")


def _write_point_checkpoint(
    directory: String,
    kind: Int,
    sequence: UInt64,
    generation: UInt64,
    bytes: List[UInt8],
) raises -> String:
    var prefix = String("point-base-") if kind == 1 else String("point-delta-")
    for claim in range(1024):
        var name = (
            prefix
            + String(sequence)
            + "-"
            + String(generation)
            + "-"
            + String(claim)
            + ".bin"
        )
        var path = directory + "/" + name
        if not create_file_exclusive(path):
            continue
        try:
            write_file_sync(path, bytes)
            sync_directory(directory)
            return name
        except error:
            remove_file_if_exists(path)
            sync_directory(directory)
            raise error^
    raise Error("no free point checkpoint output name")


def _validate_committed_graph(
    path: String, catalog: FieldCatalog, manifest: Manifest
) raises -> Bool:
    if not manifest.hnsw_name:
        return False
    var graph_path = path + "/" + manifest.hnsw_name.value()
    if not path_exists(graph_path):
        return False
    ref config = catalog.field_at(0).hnsw.value()
    if manifest.hnsw_config_fingerprint.value() != config.fingerprint():
        return False
    var mapped = try_open_compatible_hnsw_snapshot_view(
        graph_path,
        config,
        hnsw_base_sequence(manifest),
        manifest.hnsw_checksum.value(),
        manifest.hnsw_point_count.value(),
    )
    if mapped.mapping_failed():
        return Bool(
            try_read_compatible_hnsw_snapshot_owned(
                graph_path,
                config,
                hnsw_base_sequence(manifest),
                manifest.hnsw_checksum.value(),
                manifest.hnsw_point_count.value(),
            )
        )
    return mapped.hit()
