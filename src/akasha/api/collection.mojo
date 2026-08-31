from akasha.compute.simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
from akasha.compute.topk import BoundedTopK
from akasha.compute.gpu.flat_scan import DeviceBatchResult
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.api.batch import BatchMutation, BatchWriteResult
from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.document.record import (
    clone_fields,
    DocumentField,
    DocumentRecord,
    FieldProjection,
    project_document,
    validate_fields,
)
from akasha.index.bitmap import Bitmap
from akasha.index.flat import SearchResult
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup
from akasha.index.metadata import MetadataIndex
from akasha.index.sparse import SparseElement, SparseIndex, validate_sparse
from akasha.query.executor import candidate_entries
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.fusion import reciprocal_rank_fusion
from akasha.query.index_evaluator import evaluate_all, evaluate_expression
from akasha.query.planner import QueryPlanner
from akasha.api.snapshot import ReadSnapshot
from akasha.storage.compaction import CompactionPolicy
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.maintenance import (
    DEFAULT_MAINTENANCE_LIBRARY,
    MaintenanceController,
)
from akasha.storage.retired_files import RetiredFileQueue
from akasha.storage.index_cache import (
    authoritative_index_checksum,
    CACHE_HNSW_KIND,
    CACHE_METADATA_KIND,
    CacheArtifact,
    load_cache_payload,
    publish_cache,
)
from akasha.storage.filesystem import (
    atomic_replace,
    ensure_durable_directory,
    path_exists,
    remove_file_and_sync_directory_if_exists,
    sync_directory,
)
from akasha.storage.hnsw_store import (
    hnsw_snapshot_eligibility,
    hnsw_snapshot_max_bytes,
    HnswSnapshotInfo,
    try_read_compatible_hnsw_snapshot_owned,
    write_hnsw_snapshot,
)
from akasha.storage.collection_config import (
    collection_config_exists,
    load_collection_config,
    publish_collection_config,
)
from akasha.storage.manifest import (
    load_manifest,
    Manifest,
    publish_manifest,
    SegmentDescriptor,
)
from akasha.storage.lock import CollectionLock
from akasha.storage.operations import backup_storage, StorageInspection
from akasha.storage.memtable import MemTable
from akasha.storage.segment import (
    read_segment,
    SEGMENT_KIND_BASE,
    SEGMENT_KIND_DELTA,
    write_segment_v3,
)
from akasha.storage.sparse_store import (
    append_sparse_wal,
    latest_sparse_records,
    preflight_sparse_wal,
    read_sparse_segment,
    read_sparse_snapshot,
    repair_sparse_wal_tail,
    rotate_sparse_wal,
    SPARSE_SEGMENT_KIND_BASE,
    SPARSE_SEGMENT_KIND_DELTA,
    SparseWalRecord,
    write_sparse_segment,
)
from akasha.storage.wal import (
    append_wal,
    append_wal_batch,
    preflight_wal,
    repair_wal_tail,
    rotate_wal,
    WalRecord,
)
from std.math import isfinite
from std.collections import Dict
from std.memory import ArcPointer
from std.utils import BlockingScopedLock, BlockingSpinLock


comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct _ResolvedCollectionConfig(Movable):
    var config: CollectionConfig
    var needs_publication: Bool

    def __init__(
        out self, config: CollectionConfig, needs_publication: Bool
    ):
        self.config = config.copy()
        self.needs_publication = needs_publication


struct _HnswRebuildOrdinal(Comparable, Copyable, Movable):
    """A lightweight deterministic maintenance ordering key."""

    var sequence: UInt64
    var id: Int
    var ordinal: Int

    def __init__(out self, sequence: UInt64, id: Int, ordinal: Int):
        self.sequence = sequence
        self.id = id
        self.ordinal = ordinal

    def __lt__(self, other: Self) -> Bool:
        if self.sequence != other.sequence:
            return self.sequence < other.sequence
        if self.id != other.id:
            return self.id < other.id
        return self.ordinal < other.ordinal


struct PersistentCollection:
    """A durable, single-writer exact vector collection."""

    var path: String
    var dimension: Int
    var _path: String
    var _config: CollectionConfig
    var _wal_path: String
    var _memtable: MemTable
    var _last_sequence: UInt64
    var _lock: CollectionLock
    var _closed: Bool
    var _hnsw: HnswIndex
    var _hnsw_id_lookup: Optional[HnswIdOrdinalLookup]
    var _hnsw_id_lookup_dirty: Bool
    var _hnsw_id_lookup_builds: Int
    var _hnsw_available: Bool
    var _hnsw_unavailable_reason: String
    var _hnsw_mutations_since_rebuild: Int
    var _last_dense_plan_reason: String
    var _last_hnsw_rerank_candidates: Int
    var _last_hnsw_rerank_ordinal_lookups: Int
    var _last_hnsw_rerank_linear_id_scans: Int
    var _last_hnsw_rerank_payload_clones: Int
    var _last_hnsw_upsert_ordinal_lookups: Int
    var _last_hnsw_upsert_memtable_id_scans: Int
    var _last_hnsw_upsert_record_clones: Int
    var _sparse: SparseIndex
    var _sparse_wal_path: String
    var _sparse_pending: List[SparseWalRecord]
    var _metadata: MetadataIndex
    var _pins: ArcPointer[GenerationPinRegistry]
    var _retired: ArcPointer[RetiredFileQueue]
    var _writer_lock: ArcPointer[BlockingSpinLock]
    var _maintenance: MaintenanceController
    var _cache_generation: UInt64
    var _source_checksum: UInt32
    var _hnsw_checkpoint_was_hit: Bool
    var _hnsw_sidecar_max_bytes_for_test: UInt64
    var _hnsw_cache_was_hit: Bool
    var _metadata_cache_was_hit: Bool

    def __init__(
        out self,
        path: String,
        config: CollectionConfig,
        var memtable: MemTable,
        last_sequence: UInt64,
        var lock: CollectionLock,
        var hnsw: HnswIndex,
        var sparse: SparseIndex,
        var sparse_pending: List[SparseWalRecord],
        var metadata: MetadataIndex,
        maintenance_library_path: String,
        cache_generation: UInt64,
        source_checksum: UInt32,
        hnsw_checkpoint_hit: Bool,
        hnsw_cache_hit: Bool,
        metadata_cache_hit: Bool,
        hnsw_available: Bool,
        hnsw_unavailable_reason: String,
    ):
        self.path = String(copy=path)
        self.dimension = config.dimension
        self._path = String(copy=path)
        self._config = config.copy()
        self._wal_path = path + "/wal.bin"
        self._memtable = memtable^
        self._last_sequence = last_sequence
        self._lock = lock^
        self._closed = False
        self._hnsw = hnsw^
        self._hnsw_id_lookup = Optional[HnswIdOrdinalLookup]()
        self._hnsw_id_lookup_dirty = metadata.slot_count() > 0
        self._hnsw_id_lookup_builds = 0
        self._hnsw_available = hnsw_available
        self._hnsw_unavailable_reason = (
            "" if hnsw_available else String(copy=hnsw_unavailable_reason)
        )
        self._hnsw_mutations_since_rebuild = 0
        self._last_dense_plan_reason = ""
        self._last_hnsw_rerank_candidates = 0
        self._last_hnsw_rerank_ordinal_lookups = 0
        self._last_hnsw_rerank_linear_id_scans = 0
        self._last_hnsw_rerank_payload_clones = 0
        self._last_hnsw_upsert_ordinal_lookups = 0
        self._last_hnsw_upsert_memtable_id_scans = 0
        self._last_hnsw_upsert_record_clones = 0
        self._sparse = sparse^
        self._sparse_wal_path = path + "/sparse.wal"
        self._sparse_pending = sparse_pending^
        self._metadata = metadata^
        self._pins = ArcPointer(GenerationPinRegistry())
        self._retired = ArcPointer(RetiredFileQueue())
        self._writer_lock = ArcPointer(BlockingSpinLock())
        self._maintenance = MaintenanceController.start(
            path,
            config.dimension,
            self._writer_lock,
            self._pins,
            self._retired,
            maintenance_library_path,
        )
        self._cache_generation = cache_generation
        self._source_checksum = source_checksum
        self._hnsw_checkpoint_was_hit = hnsw_checkpoint_hit
        self._hnsw_sidecar_max_bytes_for_test = hnsw_snapshot_max_bytes()
        self._hnsw_cache_was_hit = hnsw_cache_hit
        self._metadata_cache_was_hit = metadata_cache_hit

    @staticmethod
    def open(
        path: String,
        dimension: Int,
        *,
        maintenance_library_path: String = DEFAULT_MAINTENANCE_LIBRARY,
    ) raises -> PersistentCollection:
        """Create or recover a collection with the legacy default identity."""
        return PersistentCollection.open_with_config(
            path,
            CollectionConfig.defaults(dimension),
            maintenance_library_path=maintenance_library_path,
        )

    @staticmethod
    def open_with_config(
        path: String,
        requested: CollectionConfig,
        *,
        maintenance_library_path: String = DEFAULT_MAINTENANCE_LIBRARY,
    ) raises -> PersistentCollection:
        """Create or recover a collection bound to one durable ANN identity."""
        requested.validate()
        _ = ensure_durable_directory(path)
        var lock = CollectionLock.acquire(path + "/collection.lock")
        var resolved = _resolve_collection_config(path, requested)
        var config = resolved.config.copy()
        var dimension = config.dimension

        var memtable = MemTable(dimension)
        var snapshot_sequence = UInt64(0)
        var cache_generation = UInt64(0)
        var manifest_path = path + "/manifest.bin"
        if path_exists(manifest_path):
            var manifest = load_manifest(path, dimension)
            cache_generation = manifest.generation
            for segment_index in range(len(manifest.segments)):
                var snapshot = read_segment(
                    path + "/" + manifest.segments[segment_index].name,
                    dimension,
                )
                if (
                    snapshot.min_sequence
                    != manifest.segments[segment_index].min_sequence
                    or snapshot.last_sequence
                    != manifest.segments[segment_index].max_sequence
                ):
                    raise Error("manifest and segment sequence mismatch")
                if (
                    snapshot.checksum
                    != manifest.segments[segment_index].checksum
                ):
                    raise Error("manifest and segment checksum mismatch")
                if (
                    manifest.segments[segment_index].level == 0
                    and snapshot.kind != SEGMENT_KIND_DELTA
                ):
                    raise Error("level-zero manifest entry must be a delta")
                if (
                    manifest.segments[segment_index].level > 0
                    and snapshot.kind != SEGMENT_KIND_BASE
                ):
                    raise Error("compacted manifest entry must be a base")
                memtable.apply_recovered_entries(snapshot.entries)
            snapshot_sequence = manifest.last_sequence

        # Preserve the exact committed dense identity before newer WAL replay.
        # A sidecar describes this checkpoint, not the post-WAL MemTable.
        var checkpoint_live_ids = Dict[Int, Bool]()
        for ordinal in range(memtable.slot_count()):
            if memtable.is_live_at(ordinal):
                checkpoint_live_ids[memtable.id_at(ordinal)] = True

        var dense_wal = preflight_wal(path + "/wal.bin", dimension)
        var last_sequence = snapshot_sequence
        for index in range(len(dense_wal.records)):
            if dense_wal.records[index].sequence <= snapshot_sequence:
                continue
            if dense_wal.records[index].is_delete:
                memtable.apply_delete(
                    dense_wal.records[index].id,
                    dense_wal.records[index].sequence,
                )
            else:
                var values = _clone_vector(dense_wal.records[index].values)
                var fields = clone_fields(dense_wal.records[index].fields)
                memtable.apply_document_upsert(
                    dense_wal.records[index].id,
                    dense_wal.records[index].sequence,
                    values^,
                    fields^,
                )
            last_sequence = dense_wal.records[index].sequence

        var sparse = SparseIndex()
        if path_exists(manifest_path):
            var sparse_manifest = load_manifest(path, dimension)
            var described_sparse_count = 0
            for descriptor_index in range(len(sparse_manifest.segments)):
                if (
                    sparse_manifest.segments[
                        descriptor_index
                    ].sparse_name.byte_length()
                    > 0
                ):
                    described_sparse_count += 1
            if described_sparse_count == 0:
                var legacy_path = (
                    path + "/sparse-" + String(snapshot_sequence) + ".bin"
                )
                if path_exists(legacy_path):
                    var legacy_records = read_sparse_snapshot(
                        legacy_path, snapshot_sequence
                    )
                    for record_index in range(len(legacy_records)):
                        sparse.upsert(
                            legacy_records[record_index].id,
                            legacy_records[record_index].elements,
                        )
            else:
                for descriptor_index in range(len(sparse_manifest.segments)):
                    if (
                        sparse_manifest.segments[
                            descriptor_index
                        ].sparse_name.byte_length()
                        == 0
                    ):
                        var legacy_path = (
                            path
                            + "/sparse-"
                            + String(
                                sparse_manifest.segments[
                                    descriptor_index
                                ].max_sequence
                            )
                            + ".bin"
                        )
                        if path_exists(legacy_path):
                            var legacy_records = read_sparse_snapshot(
                                legacy_path,
                                sparse_manifest.segments[
                                    descriptor_index
                                ].max_sequence,
                            )
                            for record_index in range(len(legacy_records)):
                                sparse.upsert(
                                    legacy_records[record_index].id,
                                    legacy_records[record_index].elements,
                                )
                        continue
                    var sparse_segment = read_sparse_segment(
                        path
                        + "/"
                        + sparse_manifest.segments[descriptor_index].sparse_name
                    )
                    if (
                        sparse_segment.min_sequence
                        != sparse_manifest.segments[
                            descriptor_index
                        ].min_sequence
                        or sparse_segment.last_sequence
                        != sparse_manifest.segments[
                            descriptor_index
                        ].max_sequence
                    ):
                        raise Error(
                            "manifest and sparse segment sequence mismatch"
                        )
                    if (
                        sparse_segment.checksum
                        != sparse_manifest.segments[
                            descriptor_index
                        ].sparse_checksum
                    ):
                        raise Error(
                            "manifest and sparse segment checksum mismatch"
                        )
                    if (
                        sparse_manifest.segments[descriptor_index].level == 0
                        and sparse_segment.kind != SPARSE_SEGMENT_KIND_DELTA
                    ):
                        raise Error("level-zero sparse entry must be a delta")
                    if (
                        sparse_manifest.segments[descriptor_index].level > 0
                        and sparse_segment.kind != SPARSE_SEGMENT_KIND_BASE
                    ):
                        raise Error("compacted sparse entry must be a base")
                    for record_index in range(len(sparse_segment.records)):
                        if sparse_segment.records[record_index].is_delete:
                            sparse.delete(
                                sparse_segment.records[record_index].id
                            )
                        else:
                            sparse.upsert(
                                sparse_segment.records[record_index].id,
                                sparse_segment.records[record_index].elements,
                            )
        var sparse_pending = List[SparseWalRecord]()
        var sparse_wal = preflight_sparse_wal(path + "/sparse.wal")
        for index in range(len(sparse_wal.records)):
            if sparse_wal.records[index].sequence <= snapshot_sequence:
                continue
            if sparse_wal.records[index].is_delete:
                sparse.delete(sparse_wal.records[index].id)
            else:
                sparse.upsert(
                    sparse_wal.records[index].id,
                    sparse_wal.records[index].elements,
                )
            sparse_pending.append(sparse_wal.records[index].clone())
            if sparse_wal.records[index].sequence > last_sequence:
                last_sequence = sparse_wal.records[index].sequence
        var recovered_sparse = sparse.records()
        for index in range(len(recovered_sparse)):
            if not Bool(memtable.get(recovered_sparse[index].id)):
                sparse.delete(recovered_sparse[index].id)

        var source_checksum = authoritative_index_checksum(memtable)
        var hnsw_load = _load_or_rebuild_hnsw(
            path,
            config,
            cache_generation,
            snapshot_sequence,
            last_sequence,
            source_checksum,
            checkpoint_live_ids,
            dense_wal.records,
            memtable,
        )
        var hnsw_cache_hit = hnsw_load.legacy_cache_hit
        var hnsw_checkpoint_hit = hnsw_load.sidecar_hit
        var hnsw_replayed_mutations = hnsw_load.replayed_mutations
        var hnsw_available = hnsw_load.available
        var hnsw_unavailable_reason = hnsw_load.failure_reason.copy()
        var hnsw = hnsw_load.take_index()
        var metadata_load = _load_or_build_metadata_cache(
            path,
            dimension,
            cache_generation,
            last_sequence,
            source_checksum,
            memtable,
        )
        var metadata_cache_hit = metadata_load.hit
        var metadata = metadata_load.take_index()

        # Publishing the immutable identity is the migration commit point.
        # Every authoritative source and any matching committed sidecar has
        # been decoded without truncating a torn WAL tail. Repair happens only
        # after the complete recovery preflight succeeds.
        if resolved.needs_publication:
            publish_collection_config(path, config)
        repair_wal_tail(path + "/wal.bin", dense_wal)
        repair_sparse_wal_tail(path + "/sparse.wal", sparse_wal)

        var collection = PersistentCollection(
            path,
            config,
            memtable^,
            last_sequence,
            lock^,
            hnsw^,
            sparse^,
            sparse_pending^,
            metadata^,
            maintenance_library_path,
            cache_generation,
            source_checksum,
            hnsw_checkpoint_hit,
            hnsw_cache_hit,
            metadata_cache_hit,
            hnsw_available,
            hnsw_unavailable_reason,
        )
        collection._hnsw_mutations_since_rebuild = hnsw_replayed_mutations
        return collection^

    def collection_config(self) -> CollectionConfig:
        """Return a defensive copy of this collection's durable identity."""
        return self._config.copy()

    def ann_metric(self) -> MetricKind:
        """Return the metric to which the future ANN graph is bound."""
        return self._config.ann_metric.copy()

    def close(mut self) raises:
        """Release this collection's single-writer ownership."""
        with BlockingScopedLock(self._writer_lock[]):
            if self._closed:
                return
            self._closed = True
        var maintenance_error = String()
        try:
            self._maintenance.close()
        except error:
            maintenance_error = String(error)
        with BlockingScopedLock(self._writer_lock[]):
            self._lock.close()
        if maintenance_error.byte_length() > 0:
            raise Error(maintenance_error)

    def background_maintenance_enabled(self) -> Bool:
        return self._maintenance.enabled()

    def schedule_maintenance(mut self) raises -> Bool:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._maintenance.request()

    def wait_for_maintenance(mut self) raises -> Bool:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
        return self._maintenance.wait()

    def last_sequence(self) raises -> UInt64:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._last_sequence

    def metadata_live_count(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._metadata.live_count()

    def metadata_match_count(self, expression: FilterExpression) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return evaluate_expression(self._metadata, expression).count()

    def hnsw_cache_hit(self) raises -> Bool:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._hnsw_cache_was_hit

    def metadata_cache_hit(self) raises -> Bool:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._metadata_cache_was_hit

    def hnsw_available(self) raises -> Bool:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._hnsw_available

    def hnsw_unavailable_reason(self) raises -> String:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._hnsw_unavailable_reason.copy()

    def last_dense_plan_reason(self) raises -> String:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._last_dense_plan_reason.copy()

    def hnsw_slot_count(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._hnsw.point_count()

    def hnsw_inactive_count(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._hnsw.inactive_count()

    def hnsw_build_distance_evaluations(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._hnsw.build_distance_evaluations()

    def last_hnsw_rerank_candidate_count(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._last_hnsw_rerank_candidates

    def last_hnsw_rerank_ordinal_lookups(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._last_hnsw_rerank_ordinal_lookups

    def last_hnsw_rerank_linear_id_scans(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._last_hnsw_rerank_linear_id_scans

    def last_hnsw_rerank_payload_clones(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._last_hnsw_rerank_payload_clones

    def last_hnsw_upsert_ordinal_lookups(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._last_hnsw_upsert_ordinal_lookups

    def last_hnsw_upsert_memtable_id_scans(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._last_hnsw_upsert_memtable_id_scans

    def last_hnsw_upsert_record_clones(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._last_hnsw_upsert_record_clones

    def hnsw_id_lookup_build_count(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._hnsw_id_lookup_builds

    def snapshot(self) raises -> ReadSnapshot:
        """Capture an immutable owned view of all currently visible records."""
        with BlockingScopedLock(self._writer_lock[]):
            return self._snapshot_unlocked()

    def _snapshot_unlocked(self) raises -> ReadSnapshot:
        self._ensure_open()
        var generation = UInt64(0)
        if path_exists(self._path + "/manifest.bin"):
            generation = load_manifest(self._path, self._config.dimension).generation
        return ReadSnapshot.capture(
            self._config.dimension,
            generation,
            self._last_sequence,
            self._memtable,
            self._sparse,
            self._pins,
        )

    def upsert(mut self, id: Int, var values: List[Float32]) raises:
        with BlockingScopedLock(self._writer_lock[]):
            self._upsert_unlocked(id, values^)

    def _upsert_unlocked(mut self, id: Int, var values: List[Float32]) raises:
        self._ensure_open()
        self._validate_vector(values)
        var metadata_slots = self._metadata.slot_count()
        var sequence = self._next_sequence()
        var wal_values = _clone_vector(values)
        var record = WalRecord.upsert(sequence, id, wal_values^)
        append_wal(self._wal_path, self._config.dimension, record)
        self._memtable.apply_upsert(id, sequence, values^)
        var metadata_fields = List[DocumentField]()
        self._metadata.upsert(id, metadata_fields^)
        self._last_sequence = sequence
        if self._metadata.slot_count() != metadata_slots:
            self._hnsw_id_lookup_dirty = True
        self._update_hnsw_after_upsert(id)
        self._invalidate_cache_hits()

    def upsert_document(
        mut self,
        id: Int,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) raises:
        with BlockingScopedLock(self._writer_lock[]):
            self._upsert_document_unlocked(id, values^, fields^)

    def _upsert_document_unlocked(
        mut self,
        id: Int,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) raises:
        self._ensure_open()
        self._validate_vector(values)
        var metadata_slots = self._metadata.slot_count()
        var sequence = self._next_sequence()
        var wal_values = _clone_vector(values)
        var wal_fields = clone_fields(fields)
        var metadata_fields = clone_fields(fields)
        var record = WalRecord.document_upsert(
            sequence, id, wal_values^, wal_fields^
        )
        append_wal(self._wal_path, self._config.dimension, record)
        self._memtable.apply_document_upsert(id, sequence, values^, fields^)
        self._metadata.upsert(id, metadata_fields^)
        self._last_sequence = sequence
        if self._metadata.slot_count() != metadata_slots:
            self._hnsw_id_lookup_dirty = True
        self._update_hnsw_after_upsert(id)
        self._invalidate_cache_hits()

    def apply_batch(
        mut self, mutations: List[BatchMutation]
    ) raises -> BatchWriteResult:
        """Validate and durably apply one all-or-nothing dense mutation batch.
        """
        with BlockingScopedLock(self._writer_lock[]):
            return self._apply_batch_unlocked(mutations)

    def _apply_batch_unlocked(
        mut self, mutations: List[BatchMutation]
    ) raises -> BatchWriteResult:
        self._ensure_open()
        if len(mutations) == 0:
            raise Error("mutation batch cannot be empty")
        if len(mutations) > 65_536:
            raise Error("mutation batch record count is too large")
        if self._last_sequence > UInt64.MAX - UInt64(len(mutations)):
            raise Error("collection sequence exhausted")

        for index in range(len(mutations)):
            if mutations[index].is_delete:
                if (
                    len(mutations[index].values) != 0
                    or len(mutations[index].fields) != 0
                ):
                    raise Error("batch delete cannot contain values or fields")
                continue
            self._validate_vector(mutations[index].values)
            validate_fields(mutations[index].fields)

        var prior_live_by_id = Dict[Int, Bool]()
        for index in range(len(mutations)):
            var id = mutations[index].id
            if id in prior_live_by_id:
                continue
            var ordinal = self._metadata.ordinal_for(id)
            prior_live_by_id[id] = (
                ordinal >= 0 and self._metadata.is_live_at(ordinal)
            )

        var first_sequence = self._last_sequence + 1
        var records = List[WalRecord](capacity=len(mutations))
        var staged_memtable = self._memtable.clone()
        for index in range(len(mutations)):
            var sequence = first_sequence + UInt64(index)
            if mutations[index].is_delete:
                records.append(WalRecord.delete(sequence, mutations[index].id))
                staged_memtable.apply_delete(mutations[index].id, sequence)
                continue
            var wal_values = _clone_vector(mutations[index].values)
            var wal_fields = clone_fields(mutations[index].fields)
            records.append(
                WalRecord.document_upsert(
                    sequence,
                    mutations[index].id,
                    wal_values^,
                    wal_fields^,
                )
            )
            var staged_values = _clone_vector(mutations[index].values)
            var staged_fields = clone_fields(mutations[index].fields)
            staged_memtable.apply_document_upsert(
                mutations[index].id,
                sequence,
                staged_values^,
                staged_fields^,
            )
        var staged_metadata = _build_metadata(staged_memtable)

        append_wal_batch(self._wal_path, self._config.dimension, records)
        var metadata_slots = self._metadata.slot_count()
        self._memtable = staged_memtable^
        self._metadata = staged_metadata^
        if self._metadata.slot_count() != metadata_slots:
            self._hnsw_id_lookup_dirty = True
        for index in range(len(mutations)):
            if mutations[index].is_delete:
                self._sparse.delete(mutations[index].id)
        var last_sequence = first_sequence + UInt64(len(mutations) - 1)
        self._last_sequence = last_sequence
        var final_mutation_by_id = Dict[Int, Int]()
        for index in range(len(mutations)):
            final_mutation_by_id[mutations[index].id] = index
        for index in range(len(mutations)):
            if not self._hnsw_available:
                break
            if final_mutation_by_id[mutations[index].id] != index:
                continue
            if mutations[index].is_delete:
                self._update_hnsw_after_delete(
                    mutations[index].id,
                    prior_live_by_id[mutations[index].id],
                )
            else:
                self._update_hnsw_after_upsert(mutations[index].id)
        self._invalidate_cache_hits()
        return BatchWriteResult(first_sequence, last_sequence, len(mutations))

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._memtable.get(id)

    def get_projected(
        self, id: Int, projection: FieldProjection
    ) raises -> Optional[DocumentRecord]:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            var document = self._memtable.get(id)
            if not Bool(document):
                return Optional[DocumentRecord]()
            return Optional(project_document(document.value(), projection))

    def upsert_sparse(mut self, id: Int, elements: List[SparseElement]) raises:
        with BlockingScopedLock(self._writer_lock[]):
            self._upsert_sparse_unlocked(id, elements)

    def _upsert_sparse_unlocked(
        mut self, id: Int, elements: List[SparseElement]
    ) raises:
        self._ensure_open()
        validate_sparse(elements)
        if not Bool(self._memtable.get(id)):
            raise Error("sparse vectors require an existing live point")
        var sequence = self._next_sequence()
        var wal_elements = elements.copy()
        var record = SparseWalRecord.upsert(sequence, id, wal_elements^)
        append_sparse_wal(self._sparse_wal_path, record)
        self._sparse.upsert(id, elements)
        self._sparse_pending.append(record.clone())
        self._last_sequence = sequence
        self._invalidate_cache_hits()

    def delete(mut self, id: Int) raises:
        with BlockingScopedLock(self._writer_lock[]):
            self._delete_unlocked(id)

    def _delete_unlocked(mut self, id: Int) raises:
        self._ensure_open()
        var metadata_slots = self._metadata.slot_count()
        var metadata_ordinal = self._metadata.ordinal_for(id)
        var was_live = (
            metadata_ordinal >= 0
            and self._metadata.is_live_at(metadata_ordinal)
        )
        var sequence = self._next_sequence()
        var record = WalRecord.delete(sequence, id)
        append_wal(self._wal_path, self._config.dimension, record)
        self._memtable.apply_delete(id, sequence)
        self._metadata.delete(id)
        self._sparse.delete(id)
        self._last_sequence = sequence
        if self._metadata.slot_count() != metadata_slots:
            self._hnsw_id_lookup_dirty = True
        self._update_hnsw_after_delete(id, was_live)
        self._invalidate_cache_hits()

    def search_dot(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        var conditions = List[FilterCondition]()
        return self._search_filtered(query, k, _DOT_METRIC, conditions)

    def search_l2(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        var conditions = List[FilterCondition]()
        return self._search_filtered(query, k, _L2_METRIC, conditions)

    def search_cosine(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        var conditions = List[FilterCondition]()
        return self._search_filtered(query, k, _COSINE_METRIC, conditions)

    def search_dot_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var snapshot = self.snapshot()
        return snapshot.search_dot_batch(queries, k, num_workers=num_workers)

    def search_l2_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var snapshot = self.snapshot()
        return snapshot.search_l2_batch(queries, k, num_workers=num_workers)

    def search_cosine_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var snapshot = self.snapshot()
        return snapshot.search_cosine_batch(queries, k, num_workers=num_workers)

    def search_device_dot_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var snapshot = self.snapshot()
        return snapshot.search_device_dot_batch[use_accelerator](
            queries, k, options
        )

    def search_device_l2_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var snapshot = self.snapshot()
        return snapshot.search_device_l2_batch[use_accelerator](
            queries, k, options
        )

    def search_device_cosine_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var snapshot = self.snapshot()
        return snapshot.search_device_cosine_batch[use_accelerator](
            queries, k, options
        )

    def search_dot_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var snapshot = self.snapshot()
        return snapshot.search_dot_where_batch(
            queries, expressions, k, num_workers=num_workers
        )

    def search_l2_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var snapshot = self.snapshot()
        return snapshot.search_l2_where_batch(
            queries, expressions, k, num_workers=num_workers
        )

    def search_cosine_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var snapshot = self.snapshot()
        return snapshot.search_cosine_where_batch(
            queries, expressions, k, num_workers=num_workers
        )

    def search_device_dot_where_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var snapshot = self.snapshot()
        return snapshot.search_device_dot_where_batch[use_accelerator](
            queries, expressions, k, options
        )

    def search_device_l2_where_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var snapshot = self.snapshot()
        return snapshot.search_device_l2_where_batch[use_accelerator](
            queries, expressions, k, options
        )

    def search_device_cosine_where_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var snapshot = self.snapshot()
        return snapshot.search_device_cosine_where_batch[use_accelerator](
            queries, expressions, k, options
        )

    def search_dot_approx(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        with BlockingScopedLock(self._writer_lock[]):
            return self._search_approx_unlocked(
                query, k, ef_search, _DOT_METRIC
            )

    def search_l2_approx(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        with BlockingScopedLock(self._writer_lock[]):
            return self._search_approx_unlocked(
                query, k, ef_search, _L2_METRIC
            )

    def search_cosine_approx(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        with BlockingScopedLock(self._writer_lock[]):
            return self._search_approx_unlocked(
                query, k, ef_search, _COSINE_METRIC
            )

    def search_dot_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        return self._search_filtered(query, k, _DOT_METRIC, conditions)

    def search_l2_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        return self._search_filtered(query, k, _L2_METRIC, conditions)

    def search_cosine_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        return self._search_filtered(query, k, _COSINE_METRIC, conditions)

    def search_dot_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_where(query, k, _DOT_METRIC, expression)

    def search_l2_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_where(query, k, _L2_METRIC, expression)

    def search_cosine_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_where(query, k, _COSINE_METRIC, expression)

    def search_dot_approx_where(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        with BlockingScopedLock(self._writer_lock[]):
            return self._search_approx_where_unlocked(
                query, k, ef_search, _DOT_METRIC, expression
            )

    def search_l2_approx_where(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        with BlockingScopedLock(self._writer_lock[]):
            return self._search_approx_where_unlocked(
                query, k, ef_search, _L2_METRIC, expression
            )

    def search_cosine_approx_where(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        with BlockingScopedLock(self._writer_lock[]):
            return self._search_approx_where_unlocked(
                query, k, ef_search, _COSINE_METRIC, expression
            )

    def search_sparse_dot(
        self, query: List[SparseElement], k: Int
    ) raises -> List[SearchResult]:
        self._ensure_open()
        return self._sparse.search_dot(query, k)

    def search_sparse_dot_where(
        self,
        query: List[SparseElement],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_sparse_where(query, k, expression)

    def search_hybrid_dot(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int = 60,
    ) raises -> List[SearchResult]:
        return self._search_hybrid(
            dense_query,
            sparse_query,
            k,
            fetch_k,
            rank_constant,
            _DOT_METRIC,
        )

    def search_hybrid_l2(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int = 60,
    ) raises -> List[SearchResult]:
        return self._search_hybrid(
            dense_query,
            sparse_query,
            k,
            fetch_k,
            rank_constant,
            _L2_METRIC,
        )

    def search_hybrid_cosine(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int = 60,
    ) raises -> List[SearchResult]:
        return self._search_hybrid(
            dense_query,
            sparse_query,
            k,
            fetch_k,
            rank_constant,
            _COSINE_METRIC,
        )

    def search_hybrid_dot_where(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_hybrid_where(
            dense_query,
            sparse_query,
            k,
            fetch_k,
            rank_constant,
            _DOT_METRIC,
            expression,
        )

    def search_hybrid_l2_where(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_hybrid_where(
            dense_query,
            sparse_query,
            k,
            fetch_k,
            rank_constant,
            _L2_METRIC,
            expression,
        )

    def search_hybrid_cosine_where(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_hybrid_where(
            dense_query,
            sparse_query,
            k,
            fetch_k,
            rank_constant,
            _COSINE_METRIC,
            expression,
        )

    def flush(mut self) raises:
        """Atomically append an immutable incremental checkpoint."""
        with BlockingScopedLock(self._writer_lock[]):
            self._flush_unlocked()

    def rebuild_hnsw(mut self) raises:
        """Explicitly rebuild the derived graph from authoritative live data."""
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            self._rebuild_hnsw_unlocked()

    def backup_to(mut self, target: String) raises -> StorageInspection:
        """Checkpoint and copy one generation while it remains pinned."""
        with BlockingScopedLock(self._writer_lock[]):
            self._flush_unlocked()
            var manifest = load_manifest(self._path, self._config.dimension)
            self._pins[].pin(manifest.generation)
            try:
                var report = backup_storage(self._path, target, self._config.dimension)
                self._pins[].unpin(manifest.generation)
                return report^
            except error:
                self._pins[].unpin(manifest.generation)
                raise Error(String(error))

    def _flush_unlocked(mut self) raises:
        self._ensure_open()
        self._reclaim_retired()
        var previous_sequence = UInt64(0)
        var generation = UInt64(1)
        var has_previous_manifest = False
        var previous_hnsw_name = String()
        var previous_hnsw_metadata_matches = False
        var descriptors = List[SegmentDescriptor]()
        if path_exists(self._path + "/manifest.bin"):
            var previous_manifest = load_manifest(self._path, self._config.dimension)
            previous_sequence = previous_manifest.last_sequence
            has_previous_manifest = True
            if Bool(previous_manifest.hnsw_name):
                previous_hnsw_name = previous_manifest.hnsw_name.value().copy()
                previous_hnsw_metadata_matches = (
                    self._hnsw_checkpoint_was_hit and
                    previous_manifest.hnsw_config_fingerprint.value()
                    == self._config.fingerprint()
                    and previous_manifest.hnsw_point_count.value()
                    == UInt64(
                        self._hnsw.point_count() - self._hnsw.inactive_count()
                    )
                    and path_exists(
                        self._path + "/" + previous_hnsw_name
                    )
                )
            if self._last_sequence < previous_sequence:
                raise Error("collection sequence precedes checkpoint")
            if previous_manifest.format_version >= 2:
                if previous_manifest.generation == UInt64.MAX:
                    raise Error("manifest generation exhausted")
                generation = previous_manifest.generation + 1
            for index in range(len(previous_manifest.segments)):
                descriptors.append(previous_manifest.segments[index].clone())

        # Task 19 policy is evaluated before any checkpoint artifact is
        # encoded so the sidecar represents the same authoritative sequence.
        self._maintain_hnsw_for_flush()
        if has_previous_manifest and self._last_sequence == previous_sequence:
            var hnsw_to_cleanup = String()
            if not previous_hnsw_metadata_matches:
                var wrote_hnsw = False
                if self._hnsw_available:
                    var eligibility = hnsw_snapshot_eligibility(
                        self._hnsw, self._hnsw_sidecar_max_bytes_for_test
                    )
                    if not eligibility.graph_usable:
                        self._mark_hnsw_unavailable("eligibility_failed")
                    if eligibility.eligible:
                        var hnsw_name = (
                            "hnsw-" + String(self._last_sequence) + ".bin"
                        )
                        var hnsw_temporary = (
                            self._path + "/" + hnsw_name + ".tmp"
                        )
                        var hnsw_info = write_hnsw_snapshot(
                            hnsw_temporary, self._hnsw, self._last_sequence
                        )
                        atomic_replace(
                            hnsw_temporary, self._path + "/" + hnsw_name
                        )
                        sync_directory(self._path)
                        var upgraded = Manifest.with_hnsw(
                            self._config.dimension,
                            generation,
                            self._last_sequence,
                            _clone_segment_descriptors(descriptors),
                            hnsw_name,
                            hnsw_info.checksum,
                            hnsw_info.config_fingerprint,
                            hnsw_info.live_point_count,
                        )
                        publish_manifest(self._path, upgraded)
                        self._hnsw_checkpoint_was_hit = True
                        wrote_hnsw = True
                if not wrote_hnsw and previous_hnsw_name.byte_length() > 0:
                    var downgraded = Manifest.with_segments(
                        self._config.dimension,
                        generation,
                        self._last_sequence,
                        _clone_segment_descriptors(descriptors),
                    )
                    publish_manifest(self._path, downgraded)
                    self._hnsw_checkpoint_was_hit = False
                    hnsw_to_cleanup = previous_hnsw_name.copy()
            rotate_wal(self._path)
            rotate_sparse_wal(self._path)
            if hnsw_to_cleanup.byte_length() > 0:
                remove_file_and_sync_directory_if_exists(
                    self._path, self._path + "/" + hnsw_to_cleanup
                )
            self._sparse_pending = List[SparseWalRecord]()
            self._publish_index_caches_best_effort()
            return

        var sparse_kind = SPARSE_SEGMENT_KIND_BASE
        var sparse_prefix = String("sparse-base-")
        var sparse_mutations = List[SparseWalRecord]()
        var sparse_records = self._sparse.records()
        for index in range(len(sparse_records)):
            var elements = sparse_records[index].elements.copy()
            sparse_mutations.append(
                SparseWalRecord.upsert(
                    self._last_sequence, sparse_records[index].id, elements^
                )
            )
        if has_previous_manifest:
            sparse_kind = SPARSE_SEGMENT_KIND_DELTA
            sparse_prefix = "sparse-delta-"
            sparse_mutations = latest_sparse_records(self._sparse_pending)
        var sparse_name = sparse_prefix + String(self._last_sequence) + ".bin"
        var sparse_temporary = self._path + "/" + sparse_name + ".tmp"
        var sparse_checksum = write_sparse_segment(
            sparse_temporary,
            sparse_kind,
            0 if not has_previous_manifest else previous_sequence + 1,
            self._last_sequence,
            sparse_mutations,
        )

        var kind = SEGMENT_KIND_BASE
        var level = 1
        var min_sequence = UInt64(0)
        var segment_prefix = String("segment-base-")
        var entries = self._memtable.live_entries()
        if has_previous_manifest:
            kind = SEGMENT_KIND_DELTA
            level = 0
            min_sequence = previous_sequence + 1
            segment_prefix = "segment-delta-"
            entries = self._memtable.entries_after(previous_sequence)
        var segment_name = segment_prefix + String(self._last_sequence) + ".bin"
        var temporary_path = self._path + "/" + segment_name + ".tmp"
        var final_path = self._path + "/" + segment_name
        var checksum = write_segment_v3(
            temporary_path,
            self._config.dimension,
            kind,
            min_sequence,
            self._last_sequence,
            entries,
        )
        var hnsw_name = "hnsw-" + String(self._last_sequence) + ".bin"
        var hnsw_temporary = self._path + "/" + hnsw_name + ".tmp"
        var hnsw_info = Optional[HnswSnapshotInfo]()
        if self._hnsw_available:
            var eligibility = hnsw_snapshot_eligibility(
                self._hnsw, self._hnsw_sidecar_max_bytes_for_test
            )
            if not eligibility.graph_usable:
                self._mark_hnsw_unavailable("eligibility_failed")
            if eligibility.eligible:
                hnsw_info = Optional(
                    write_hnsw_snapshot(
                        hnsw_temporary, self._hnsw, self._last_sequence
                    )
                )

        # Every immutable data file is durable before the manifest commit
        # point. One directory barrier covers all completed renames.
        atomic_replace(sparse_temporary, self._path + "/" + sparse_name)
        atomic_replace(temporary_path, final_path)
        if Bool(hnsw_info):
            atomic_replace(hnsw_temporary, self._path + "/" + hnsw_name)
        sync_directory(self._path)
        descriptors.append(
            SegmentDescriptor.with_sparse(
                level,
                min_sequence,
                self._last_sequence,
                checksum,
                segment_name,
                sparse_checksum,
                sparse_name,
            )
        )
        var manifest: Manifest
        if Bool(hnsw_info):
            manifest = Manifest.with_hnsw(
                self._config.dimension,
                generation,
                self._last_sequence,
                descriptors^,
                hnsw_name,
                hnsw_info.value().checksum,
                hnsw_info.value().config_fingerprint,
                hnsw_info.value().live_point_count,
            )
        else:
            manifest = Manifest.with_segments(
                self._config.dimension,
                generation,
                self._last_sequence,
                descriptors^,
            )
        publish_manifest(self._path, manifest)
        self._hnsw_checkpoint_was_hit = Bool(hnsw_info)
        rotate_wal(self._path)
        rotate_sparse_wal(self._path)
        self._sparse_pending = List[SparseWalRecord]()
        if (
            previous_hnsw_name.byte_length() > 0
            and previous_hnsw_name != hnsw_name
        ):
            remove_file_and_sync_directory_if_exists(
                self._path, self._path + "/" + previous_hnsw_name
            )
        self._publish_index_caches_best_effort()
        var policy = CompactionPolicy(4)
        if policy.should_compact(manifest):
            if self._maintenance.enabled():
                _ = self._maintenance.request()
            else:
                self._compact_committed(manifest^)

    def compact(mut self) raises:
        """Replace the committed segment set with one complete live base."""
        with BlockingScopedLock(self._writer_lock[]):
            self._compact_unlocked()

    def _compact_unlocked(mut self) raises:
        self._ensure_open()
        self._flush_unlocked()
        if not path_exists(self._path + "/manifest.bin"):
            return
        var previous = load_manifest(self._path, self._config.dimension)
        if len(previous.segments) <= 1:
            return
        self._compact_committed(previous^)

    def _compact_committed(mut self, var previous: Manifest) raises:
        if previous.generation == UInt64.MAX:
            raise Error("manifest generation exhausted")

        var sparse_name = "sparse-base-" + String(self._last_sequence) + ".bin"
        var sparse_temporary = self._path + "/" + sparse_name + ".tmp"
        var sparse_mutations = List[SparseWalRecord]()
        var sparse_records = self._sparse.records()
        for index in range(len(sparse_records)):
            var elements = sparse_records[index].elements.copy()
            sparse_mutations.append(
                SparseWalRecord.upsert(
                    self._last_sequence, sparse_records[index].id, elements^
                )
            )
        var sparse_checksum = write_sparse_segment(
            sparse_temporary,
            SPARSE_SEGMENT_KIND_BASE,
            0,
            self._last_sequence,
            sparse_mutations,
        )
        atomic_replace(sparse_temporary, self._path + "/" + sparse_name)
        sync_directory(self._path)

        var segment_name = (
            "segment-base-" + String(self._last_sequence) + ".bin"
        )
        var segment_temporary = self._path + "/" + segment_name + ".tmp"
        var live_entries = self._memtable.live_entries()
        var checksum = write_segment_v3(
            segment_temporary,
            self._config.dimension,
            SEGMENT_KIND_BASE,
            0,
            self._last_sequence,
            live_entries,
        )
        atomic_replace(segment_temporary, self._path + "/" + segment_name)
        sync_directory(self._path)

        var descriptors = List[SegmentDescriptor]()
        descriptors.append(
            SegmentDescriptor.with_sparse(
                1,
                0,
                self._last_sequence,
                checksum,
                segment_name,
                sparse_checksum,
                sparse_name,
            )
        )
        var compacted: Manifest
        if Bool(previous.hnsw_name):
            compacted = Manifest.with_hnsw(
                self._config.dimension,
                previous.generation + 1,
                self._last_sequence,
                descriptors^,
                previous.hnsw_name.value(),
                previous.hnsw_checksum.value(),
                previous.hnsw_config_fingerprint.value(),
                previous.hnsw_point_count.value(),
            )
        else:
            compacted = Manifest.with_segments(
                self._config.dimension,
                previous.generation + 1,
                self._last_sequence,
                descriptors^,
            )
        publish_manifest(self._path, compacted)

        self._publish_index_caches_best_effort()

        self._retire_or_reclaim(previous, segment_name, sparse_name)

    def maintenance(mut self) raises -> Bool:
        """Run synchronous compaction when the default L0 threshold is met."""
        with BlockingScopedLock(self._writer_lock[]):
            return self._maintenance_unlocked()

    def _maintenance_unlocked(mut self) raises -> Bool:
        self._ensure_open()
        self._reclaim_retired()
        self._flush_unlocked()
        if not path_exists(self._path + "/manifest.bin"):
            return False
        var manifest = load_manifest(self._path, self._config.dimension)
        var policy = CompactionPolicy(4)
        if not policy.should_compact(manifest):
            return False
        self._compact_committed(manifest^)
        return True

    def _retire_or_reclaim(
        mut self,
        previous: Manifest,
        retained_dense: String,
        retained_sparse: String,
    ) raises:
        var removed = List[String]()
        for index in range(len(previous.segments)):
            if previous.segments[index].name != retained_dense:
                removed.append(self._path + "/" + previous.segments[index].name)
            if (
                previous.segments[index].sparse_name.byte_length() > 0
                and previous.segments[index].sparse_name != retained_sparse
            ):
                removed.append(
                    self._path + "/" + previous.segments[index].sparse_name
                )

        self._retired[].retire_or_reclaim(
            self._path, previous.generation, removed, self._pins
        )

    def _reclaim_retired(mut self) raises:
        self._retired[].reclaim(self._path, self._pins)

    def _search_filtered(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        self._ensure_open()
        self._validate_vector(query)
        if k <= 0:
            raise Error("k must be positive")
        for index in range(len(conditions)):
            conditions[index].validate()
        var candidates = evaluate_all(self._metadata, conditions)
        return self._search_candidates(query, k, metric, candidates)

    def _search_approx_unlocked(
        mut self, query: List[Float32], k: Int, ef_search: Int, metric: Int
    ) raises -> List[SearchResult]:
        self._ensure_open()
        self._validate_vector(query)
        if k <= 0:
            raise Error("k must be positive")
        if ef_search <= 0:
            raise Error("ef_search must be positive")
        var count = self._metadata.live_count()
        var plan = QueryPlanner.plan_dense(
            count,
            count,
            k,
            ef_search,
            self._config.max_ef_search,
            False,
            self._metric_compatible(metric),
            self._hnsw_available,
        )
        self._last_dense_plan_reason = plan.reason.copy()
        if not plan.use_hnsw:
            var conditions = List[FilterCondition]()
            return self._search_filtered(query, k, metric, conditions)
        try:
            var candidates = self._hnsw.search(
                query, k, ef_search=plan.initial_ef
            )
            var allowed = Optional[Bitmap]()
            var expected_count = k
            if expected_count > count:
                expected_count = count
            return self._finish_hnsw_candidates(
                query,
                k,
                metric,
                candidates,
                expected_count,
                allowed,
            )
        except:
            var conditions = List[FilterCondition]()
            var exact = self._search_filtered(query, k, metric, conditions)
            self._mark_hnsw_unavailable("search_failed")
            self._last_dense_plan_reason = "graph_unavailable"
            return exact^

    def _search_approx_where_unlocked(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        metric: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._ensure_open()
        self._validate_vector(query)
        if k <= 0:
            raise Error("k must be positive")
        if ef_search <= 0:
            raise Error("ef_search must be positive")
        expression.validate()
        var matched = evaluate_expression(self._metadata, expression)
        var matched_count = matched.count()
        var total_count = self._metadata.live_count()
        var plan = QueryPlanner.plan_dense(
            total_count,
            matched_count,
            k,
            ef_search,
            self._config.max_ef_search,
            True,
            self._metric_compatible(metric),
            self._hnsw_available,
        )
        self._last_dense_plan_reason = plan.reason.copy()
        if not plan.use_hnsw:
            return self._search_where(query, k, metric, expression)
        if not self._ensure_hnsw_id_lookup():
            self._last_dense_plan_reason = "graph_unavailable"
            return self._search_where(query, k, metric, expression)
        try:
            var allowed_bitmap = matched.clone()
            var eligibility = HnswEligibility(
                matched^, self._hnsw_id_lookup.value()
            )
            var candidates = self._hnsw.search_allowed_with_widening(
                query,
                k,
                plan.initial_ef,
                plan.max_ef,
                eligibility,
            )
            if self._hnsw.last_search_stats.fallback_reason != "":
                self._last_dense_plan_reason = (
                    self._hnsw.last_search_stats.fallback_reason.copy()
                )
            var allowed = Optional(allowed_bitmap^)
            var expected_count = k
            if expected_count > matched_count:
                expected_count = matched_count
            return self._finish_hnsw_candidates(
                query,
                k,
                metric,
                candidates,
                expected_count,
                allowed,
            )
        except:
            var exact = self._search_where(query, k, metric, expression)
            self._mark_hnsw_unavailable("search_failed")
            self._last_dense_plan_reason = "graph_unavailable"
            return exact^

    def _search_where(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._ensure_open()
        self._validate_vector(query)
        if k <= 0:
            raise Error("k must be positive")
        expression.validate()
        var candidates = evaluate_expression(self._metadata, expression)
        return self._search_candidates(query, k, metric, candidates)

    def _search_candidates(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        candidates: Bitmap,
    ) raises -> List[SearchResult]:
        if candidates.count() == 0:
            return List[SearchResult]()
        var result_count = k
        if result_count > candidates.count():
            result_count = candidates.count()
        var topk = BoundedTopK(
            result_count, smaller_is_better=metric == _L2_METRIC
        )
        var entries = candidate_entries(self._memtable, candidates)
        for index in range(len(entries)):
            var score: Float32
            if metric == _DOT_METRIC:
                score = simd_dot_product(query, entries[index].values)
            elif metric == _L2_METRIC:
                score = simd_l2_squared_distance(query, entries[index].values)
            else:
                score = simd_cosine_similarity(query, entries[index].values)
            topk.offer(entries[index].id, score)

        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def _search_sparse_where(
        self,
        query: List[SparseElement],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._ensure_open()
        validate_sparse(query)
        if k <= 0:
            raise Error("k must be positive")
        expression.validate()
        var matched = evaluate_expression(self._metadata, expression)
        var count = self._sparse.point_count()
        if count == 0:
            return List[SearchResult]()
        var candidates = self._sparse.search_dot(query, count)
        var result = List[SearchResult]()
        for candidate in candidates:
            if self._metadata.contains_id(matched, candidate.id):
                result.append(candidate)
                if len(result) == k:
                    break
        return result^

    def _search_hybrid(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int,
        metric: Int,
    ) raises -> List[SearchResult]:
        self._validate_hybrid(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )
        var conditions = List[FilterCondition]()
        var dense = self._search_filtered(
            dense_query, fetch_k, metric, conditions
        )
        var sparse = self._sparse.search_dot(sparse_query, fetch_k)
        return reciprocal_rank_fusion(dense, sparse, k, rank_constant)

    def _search_hybrid_where(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int,
        metric: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._validate_hybrid(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )
        expression.validate()
        var dense = self._search_where(dense_query, fetch_k, metric, expression)
        var sparse = self._search_sparse_where(
            sparse_query, fetch_k, expression
        )
        return reciprocal_rank_fusion(dense, sparse, k, rank_constant)

    def _validate_hybrid(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int,
    ) raises:
        self._ensure_open()
        self._validate_vector(dense_query)
        validate_sparse(sparse_query)
        if k <= 0 or fetch_k < k:
            raise Error("hybrid fetch_k must be at least positive k")
        if rank_constant <= 0:
            raise Error("RRF rank constant must be positive")

    def _validate_vector(self, values: List[Float32]) raises:
        if len(values) != self._config.dimension:
            raise Error("vector dimension does not match collection")
        for value in values:
            if not isfinite(value):
                raise Error("vectors must contain only finite values")

    def _ensure_open(self) raises:
        if self._closed:
            raise Error("collection is closed")
        if self.path != self._path:
            raise Error("public collection path copy diverged from identity")
        if self.dimension != self._config.dimension:
            raise Error(
                "public collection dimension copy diverged from identity"
            )
        self._maintenance.check()

    def _update_hnsw_after_upsert(mut self, id: Int):
        self._last_hnsw_upsert_ordinal_lookups = 0
        self._last_hnsw_upsert_memtable_id_scans = 0
        self._last_hnsw_upsert_record_clones = 0
        if not self._hnsw_available:
            return
        try:
            var ordinal = self._metadata.ordinal_for(id)
            self._last_hnsw_upsert_ordinal_lookups += 1
            if (
                ordinal < 0
                or not self._metadata.is_live_at(ordinal)
                or self._metadata.id_at(ordinal) != id
                or ordinal >= self._memtable.slot_count()
                or not self._memtable.is_live_at(ordinal)
                or self._memtable.id_at(ordinal) != id
            ):
                raise Error("HNSW upsert source is not authoritative and current")
            ref authoritative = self._memtable.entry_ref_at(ordinal)
            self._hnsw.upsert(id, authoritative.values)
            self._record_hnsw_mutation()
        except:
            self._mark_hnsw_unavailable("mutation_failed")

    def _ensure_hnsw_id_lookup(mut self) -> Bool:
        if Bool(self._hnsw_id_lookup) and not self._hnsw_id_lookup_dirty:
            return True
        try:
            var lookup = _build_hnsw_id_lookup(self._metadata)
            self._hnsw_id_lookup = Optional(lookup^)
            self._hnsw_id_lookup_dirty = False
            self._hnsw_id_lookup_builds += 1
            return True
        except:
            self._mark_hnsw_unavailable("eligibility_failed")
            return False

    def _update_hnsw_after_delete(mut self, id: Int, was_live: Bool):
        if not self._hnsw_available:
            return
        var deleted = self._hnsw.delete(id)
        if (was_live and not deleted) or not self._hnsw.valid:
            self._mark_hnsw_unavailable("mutation_failed")
        elif deleted:
            self._record_hnsw_mutation()

    def _record_hnsw_mutation(mut self):
        # The counter is a threshold latch, not an unbounded metric.
        if self._hnsw_mutations_since_rebuild < self._config.delta_max_points:
            self._hnsw_mutations_since_rebuild += 1

    def _mark_hnsw_unavailable(mut self, reason: String):
        self._hnsw_available = False
        self._hnsw_unavailable_reason = String(copy=reason)
        self._hnsw_checkpoint_was_hit = False

    def _hnsw_requires_maintenance(self) -> Bool:
        return (
            not self._hnsw_available
            or self._hnsw.needs_rebuild()
            or self._hnsw_mutations_since_rebuild
            >= self._config.delta_max_points
        )

    def _maintain_hnsw_for_flush(mut self):
        if not self._hnsw_requires_maintenance():
            return
        try:
            self._rebuild_hnsw_unlocked()
        except:
            # The authoritative checkpoint has already committed. A derived
            # graph failure only disables ANN until later maintenance retries.
            self._mark_hnsw_unavailable("rebuild_failed")

    def _rebuild_hnsw_unlocked(mut self) raises:
        var staged: HnswIndex
        try:
            staged = _build_hnsw(self._memtable, self._config)
        except error:
            self._mark_hnsw_unavailable("rebuild_failed")
            raise Error(String(error))
        self._hnsw = staged^
        self._hnsw_available = True
        self._hnsw_unavailable_reason = ""
        self._hnsw_mutations_since_rebuild = 0
        self._hnsw_checkpoint_was_hit = False
        self._hnsw_cache_was_hit = False

    def _metric_compatible(self, metric: Int) -> Bool:
        if metric == _DOT_METRIC:
            return self._config.ann_metric == MetricKind.dot()
        if metric == _L2_METRIC:
            return self._config.ann_metric == MetricKind.l2()
        return self._config.ann_metric == MetricKind.cosine()

    def _finish_hnsw_candidates(
        mut self,
        query: List[Float32],
        k: Int,
        metric: Int,
        candidates: List[SearchResult],
        expected_count: Int,
        allowed: Optional[Bitmap],
    ) raises -> List[SearchResult]:
        try:
            return self._rerank_hnsw_candidates(
                query,
                k,
                metric,
                candidates,
                expected_count,
                allowed,
            )
        except:
            var exact_candidates: Bitmap
            if Bool(allowed):
                exact_candidates = allowed.value().clone()
            else:
                exact_candidates = self._metadata.live_universe()
            var exact = self._search_candidates(
                query, k, metric, exact_candidates
            )
            self._mark_hnsw_unavailable("candidate_invalid")
            self._last_dense_plan_reason = "graph_unavailable"
            return exact^

    def _rerank_hnsw_candidates(
        mut self,
        query: List[Float32],
        k: Int,
        metric: Int,
        candidates: List[SearchResult],
        expected_count: Int,
        allowed: Optional[Bitmap],
    ) raises -> List[SearchResult]:
        self._last_hnsw_rerank_candidates = len(candidates)
        self._last_hnsw_rerank_ordinal_lookups = 0
        self._last_hnsw_rerank_linear_id_scans = 0
        self._last_hnsw_rerank_payload_clones = 0
        if expected_count < 0 or len(candidates) != expected_count:
            raise Error("HNSW candidate count does not satisfy query contract")
        if expected_count == 0:
            return List[SearchResult]()
        if k <= 0 or expected_count > k:
            raise Error("HNSW candidate target is invalid")
        var topk = BoundedTopK(
            expected_count, smaller_is_better=metric == _L2_METRIC
        )
        var seen = Dict[Int, Bool]()
        for index in range(len(candidates)):
            var id = candidates[index].id
            if id in seen:
                raise Error("HNSW candidate IDs must be unique")
            seen[id] = True
            var ordinal = self._metadata.ordinal_for(id)
            self._last_hnsw_rerank_ordinal_lookups += 1
            if (
                ordinal < 0
                or not self._metadata.is_live_at(ordinal)
                or self._metadata.id_at(ordinal) != id
                or ordinal >= self._memtable.slot_count()
                or not self._memtable.is_live_at(ordinal)
                or self._memtable.id_at(ordinal) != id
            ):
                raise Error("HNSW candidate is not authoritative and current")
            if Bool(allowed) and not allowed.value().contains(ordinal):
                raise Error("HNSW candidate is outside filter eligibility")
            ref authoritative = self._memtable.entry_ref_at(ordinal)
            ref vector = authoritative.values
            var score: Float32
            if metric == _DOT_METRIC:
                score = simd_dot_product(query, vector)
            elif metric == _L2_METRIC:
                score = simd_l2_squared_distance(query, vector)
            else:
                score = simd_cosine_similarity(query, vector)
            topk.offer(id, score)
        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def _invalidate_cache_hits(mut self):
        self._hnsw_cache_was_hit = False
        self._metadata_cache_was_hit = False

    def _publish_index_caches_best_effort(mut self):
        try:
            var generation = UInt64(0)
            if path_exists(self._path + "/manifest.bin"):
                generation = load_manifest(
                    self._path, self._config.dimension
                ).generation
            var checksum = authoritative_index_checksum(self._memtable)
            var metadata_payload = self._metadata.encode_cache_payload()
            var metadata_artifact = CacheArtifact(
                CACHE_METADATA_KIND,
                self._config.dimension,
                generation,
                self._last_sequence,
                checksum,
                metadata_payload^,
            )
            publish_cache(self._path, "metadata.cache", metadata_artifact)
            if self._hnsw_available:
                var hnsw_payload = self._hnsw.encode_cache_payload()
                var hnsw_artifact = CacheArtifact(
                    CACHE_HNSW_KIND,
                    self._config.dimension,
                    generation,
                    self._last_sequence,
                    checksum,
                    hnsw_payload^,
                )
                publish_cache(self._path, "hnsw.cache", hnsw_artifact)
            self._cache_generation = generation
            self._source_checksum = checksum
        except:
            # Derived cache publication cannot affect query/write correctness.
            pass

    def _next_sequence(self) raises -> UInt64:
        if self._last_sequence == UInt64.MAX:
            raise Error("collection sequence exhausted")
        return self._last_sequence + 1


def _clone_vector(values: List[Float32]) -> List[Float32]:
    var result = List[Float32](capacity=len(values))
    for value in values:
        result.append(value)
    return result^


def _resolve_collection_config(
    path: String, requested: CollectionConfig
) raises -> _ResolvedCollectionConfig:
    """Resolve durable identity without publishing or repairing payloads.

    The caller owns the collection lock. Existing authoritative files are
    detected so an explicit non-default identity cannot reinterpret a legacy
    L2/F32 collection. The caller publishes only after full recovery preflight.
    """
    if collection_config_exists(path):
        var existing = load_collection_config(path)
        _require_matching_config(existing, requested)
        return _ResolvedCollectionConfig(existing, False)

    var has_legacy_data = (
        path_exists(path + "/manifest.bin")
        or path_exists(path + "/wal.bin")
        or path_exists(path + "/sparse.wal")
        or path_exists(path + "/sparse-0.bin")
    )
    if has_legacy_data:
        var legacy = CollectionConfig.defaults(requested.dimension)
        _require_matching_config(legacy, requested)
    return _ResolvedCollectionConfig(requested, True)


def _require_matching_config(
    existing: CollectionConfig, requested: CollectionConfig
) raises:
    """Reject the first immutable identity mismatch with a useful message."""
    if existing.dimension != requested.dimension:
        _raise_config_mismatch("dimension", existing, requested)
    if existing.ann_metric != requested.ann_metric:
        _raise_config_mismatch("ann_metric", existing, requested)
    if existing.scalar_kind != requested.scalar_kind:
        _raise_config_mismatch("scalar_kind", existing, requested)
    if existing.m != requested.m:
        _raise_config_mismatch("m", existing, requested)
    if existing.m0 != requested.m0:
        _raise_config_mismatch("m0", existing, requested)
    if existing.ef_construction != requested.ef_construction:
        _raise_config_mismatch("ef_construction", existing, requested)
    if existing.default_ef_search != requested.default_ef_search:
        _raise_config_mismatch("default_ef_search", existing, requested)
    if existing.max_ef_search != requested.max_ef_search:
        _raise_config_mismatch("max_ef_search", existing, requested)
    if existing.max_level != requested.max_level:
        _raise_config_mismatch("max_level", existing, requested)
    if (
        existing.rebuild_inactive_percent
        != requested.rebuild_inactive_percent
    ):
        _raise_config_mismatch(
            "rebuild_inactive_percent", existing, requested
        )
    if existing.delta_max_points != requested.delta_max_points:
        _raise_config_mismatch("delta_max_points", existing, requested)
    if existing.level_seed != requested.level_seed:
        _raise_config_mismatch("level_seed", existing, requested)


def _raise_config_mismatch(
    field: String,
    persisted: CollectionConfig,
    requested: CollectionConfig,
) raises:
    raise Error(
        String(
            "collection configuration mismatch: ",
            field,
            " persisted_fingerprint=",
            persisted.fingerprint(),
            " requested_fingerprint=",
            requested.fingerprint(),
        )
    )


def _build_hnsw(
    memtable: MemTable, config: CollectionConfig
) raises -> HnswIndex:
    """Stage a deterministic graph while borrowing authoritative vectors."""
    var order = List[_HnswRebuildOrdinal]()
    for ordinal in range(memtable.slot_count()):
        if not memtable.is_live_at(ordinal):
            continue
        ref entry = memtable.entry_ref_at(ordinal)
        order.append(_HnswRebuildOrdinal(entry.sequence, entry.id, ordinal))
    sort(Span(order))

    var index = HnswIndex(config)
    for order_index in range(len(order)):
        ref entry = memtable.entry_ref_at(order[order_index].ordinal)
        if (
            entry.tombstone
            or entry.sequence != order[order_index].sequence
            or entry.id != order[order_index].id
        ):
            raise Error("HNSW rebuild source changed during staging")
        index.add(entry.id, entry.values)
    index.validate_structure()
    return index^


def _build_metadata(memtable: MemTable) raises -> MetadataIndex:
    var index = MetadataIndex()
    index.begin_bulk()
    for ordinal in range(memtable.slot_count()):
        var entry = memtable.entry_at(ordinal)
        if entry.tombstone:
            index.delete(entry.id)
        else:
            var fields = clone_fields(entry.fields)
            index.upsert(entry.id, fields^)
    index.finish_bulk()
    if index.slot_count() != memtable.slot_count():
        raise Error("metadata index and memtable slot alignment failed")
    return index^


def _build_hnsw_id_lookup(
    metadata: MetadataIndex
) raises -> HnswIdOrdinalLookup:
    var ordinals = Dict[Int, Int]()
    for ordinal in range(metadata.slot_count()):
        ordinals[metadata.id_at(ordinal)] = ordinal
    return HnswIdOrdinalLookup(ordinals^, metadata.slot_count())


def _clone_segment_descriptors(
    descriptors: List[SegmentDescriptor],
) raises -> List[SegmentDescriptor]:
    var cloned = List[SegmentDescriptor](capacity=len(descriptors))
    for index in range(len(descriptors)):
        cloned.append(descriptors[index].clone())
    return cloned^


struct _HnswCacheLoad(Movable):
    var index: HnswIndex
    var hit: Bool

    def __init__(out self, var index: HnswIndex, hit: Bool):
        self.index = index^
        self.hit = hit

    def take_index(mut self) raises -> HnswIndex:
        var config = self.index.config.copy()
        var replacement = HnswIndex(config)
        var result = self.index^
        self.index = replacement^
        return result^


struct _HnswRecoveryLoad(Movable):
    var index: HnswIndex
    var sidecar_hit: Bool
    var legacy_cache_hit: Bool
    var replayed_mutations: Int
    var available: Bool
    var failure_reason: String

    def __init__(
        out self,
        var index: HnswIndex,
        sidecar_hit: Bool,
        legacy_cache_hit: Bool,
        replayed_mutations: Int,
        available: Bool,
        failure_reason: String,
    ):
        self.index = index^
        self.sidecar_hit = sidecar_hit
        self.legacy_cache_hit = legacy_cache_hit
        self.replayed_mutations = replayed_mutations
        self.available = available
        self.failure_reason = String(copy=failure_reason)

    def take_index(mut self) raises -> HnswIndex:
        var config = self.index.config.copy()
        var replacement = HnswIndex(config)
        var result = self.index^
        self.index = replacement^
        return result^


struct _MetadataCacheLoad(Movable):
    var index: MetadataIndex
    var hit: Bool

    def __init__(out self, var index: MetadataIndex, hit: Bool):
        self.index = index^
        self.hit = hit

    def take_index(mut self) raises -> MetadataIndex:
        var replacement = MetadataIndex()
        var result = self.index^
        self.index = replacement^
        return result^


def _load_hnsw_cache(
    path: String,
    config: CollectionConfig,
    generation: UInt64,
    sequence: UInt64,
    source_checksum: UInt32,
    memtable: MemTable,
) raises -> _HnswCacheLoad:
    var cached = load_cache_payload(
        path + "/hnsw.cache",
        CACHE_HNSW_KIND,
        config.dimension,
        generation,
        sequence,
        source_checksum,
    )
    if Bool(cached):
        try:
            var payload = cached.value().copy()
            var decoded = HnswIndex.decode_cache_payload_with_config(
                config, payload^
            )
            var live_count = 0
            for ordinal in range(memtable.slot_count()):
                if not memtable.is_live_at(ordinal):
                    continue
                live_count += 1
                if not Bool(
                    decoded.graph.current_slot(memtable.id_at(ordinal))
                ):
                    raise Error("HNSW cache current point IDs mismatch")
            if decoded.point_count() != live_count:
                raise Error("HNSW cache live point count mismatch")
            return _HnswCacheLoad(decoded^, True)
        except:
            pass
    var empty = HnswIndex(config)
    return _HnswCacheLoad(empty^, False)


def _load_or_rebuild_hnsw(
    path: String,
    config: CollectionConfig,
    generation: UInt64,
    checkpoint_sequence: UInt64,
    last_sequence: UInt64,
    source_checksum: UInt32,
    checkpoint_live_ids: Dict[Int, Bool],
    wal_records: List[WalRecord],
    memtable: MemTable,
) raises -> _HnswRecoveryLoad:
    """Recover the committed graph, then apply authoritative newer WAL."""
    var has_manifest = path_exists(path + "/manifest.bin")
    if has_manifest:
        var manifest = load_manifest(path, config.dimension)
        if Bool(manifest.hnsw_name):
            var metadata_matches = (
                config.scalar_kind == ScalarKind.f32()
                and
                manifest.hnsw_config_fingerprint.value()
                == config.fingerprint()
                and manifest.hnsw_point_count.value()
                == UInt64(len(checkpoint_live_ids))
            )
            var sidecar_path = path + "/" + manifest.hnsw_name.value()
            if metadata_matches and path_exists(sidecar_path):
                var compatible = try_read_compatible_hnsw_snapshot_owned(
                    sidecar_path,
                    config,
                    checkpoint_sequence,
                    manifest.hnsw_checksum.value(),
                    manifest.hnsw_point_count.value(),
                )
                if Bool(compatible):
                    var decoded = compatible.take()
                    if _hnsw_matches_ids(decoded, checkpoint_live_ids):
                        try:
                            var replayed = _replay_hnsw_wal(
                                decoded,
                                checkpoint_sequence,
                                wal_records,
                                config,
                            )
                            if _hnsw_matches_memtable(decoded, memtable):
                                decoded.validate_structure()
                                # A committed v3 sidecar always wins. Legacy
                                # cache bytes are not even opened on this path.
                                return _HnswRecoveryLoad(
                                    decoded^, True, False, replayed, True, ""
                                )
                        except:
                            pass
            # Missing files and stale descriptor/header metadata are derived
            # acceleration misses. They never invalidate authoritative data.
            return _rebuild_hnsw_for_recovery(memtable, config)

    # Legacy manifests may still use the optional cache during migration.
    # A miss always rebuilds from the fully recovered authoritative MemTable.
    var legacy = _load_hnsw_cache(
        path,
        config,
        generation,
        last_sequence,
        source_checksum,
        memtable,
    )
    if legacy.hit:
        var cached = legacy.take_index()
        return _HnswRecoveryLoad(cached^, False, True, 0, True, "")
    return _rebuild_hnsw_for_recovery(memtable, config)


def _rebuild_hnsw_for_recovery(
    memtable: MemTable, config: CollectionConfig
) raises -> _HnswRecoveryLoad:
    try:
        var rebuilt = _build_hnsw(memtable, config)
        return _HnswRecoveryLoad(
            rebuilt^, False, False, 0, True, ""
        )
    except:
        # Authoritative records remain queryable through exact plans when the
        # configured graph backend cannot represent this scalar/layout.
        var unavailable = HnswIndex(config)
        return _HnswRecoveryLoad(
            unavailable^, False, False, 0, False, "rebuild_failed"
        )


def _hnsw_matches_ids(
    index: HnswIndex, ids: Dict[Int, Bool]
) -> Bool:
    if index.point_count() - index.inactive_count() != len(ids):
        return False
    for id in ids:
        if not Bool(index.graph.current_slot(id)):
            return False
    return True


def _hnsw_matches_memtable(
    index: HnswIndex, memtable: MemTable
) raises -> Bool:
    var ids = Dict[Int, Bool]()
    for ordinal in range(memtable.slot_count()):
        if memtable.is_live_at(ordinal):
            ids[memtable.id_at(ordinal)] = True
    return _hnsw_matches_ids(index, ids)


def _replay_hnsw_wal(
    mut index: HnswIndex,
    checkpoint_sequence: UInt64,
    records: List[WalRecord],
    config: CollectionConfig,
) raises -> Int:
    var replayed = 0
    for record_index in range(len(records)):
        if records[record_index].sequence <= checkpoint_sequence:
            continue
        if records[record_index].is_delete:
            _ = index.delete(records[record_index].id)
            if not index.valid:
                raise Error("HNSW WAL delete replay invalidated graph")
        else:
            index.upsert(
                records[record_index].id, records[record_index].values
            )
        if replayed < config.delta_max_points:
            replayed += 1
    return replayed


def _load_or_build_metadata_cache(
    path: String,
    dimension: Int,
    generation: UInt64,
    sequence: UInt64,
    source_checksum: UInt32,
    memtable: MemTable,
) raises -> _MetadataCacheLoad:
    var cached = load_cache_payload(
        path + "/metadata.cache",
        CACHE_METADATA_KIND,
        dimension,
        generation,
        sequence,
        source_checksum,
    )
    if Bool(cached):
        try:
            var payload = cached.value().copy()
            var decoded = MetadataIndex.decode_cache_payload(payload^)
            if (
                decoded.slot_count() != memtable.slot_count()
                or decoded.live_count() != len(memtable.live_entries())
            ):
                raise Error("metadata cache slot alignment mismatch")
            return _MetadataCacheLoad(decoded^, True)
        except:
            pass

    var rebuilt = _build_metadata(memtable)
    try:
        var payload = rebuilt.encode_cache_payload()
        var artifact = CacheArtifact(
            CACHE_METADATA_KIND,
            dimension,
            generation,
            sequence,
            source_checksum,
            payload^,
        )
        publish_cache(path, "metadata.cache", artifact)
    except:
        pass
    return _MetadataCacheLoad(rebuilt^, False)
