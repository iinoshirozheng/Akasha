from akasha.document.point_state import FieldUpdate, PointMutation, PointState
from akasha.document.vector_schema import (
    FieldCatalog,
    VectorFieldSpec,
    legacy_vector_fields,
)
from akasha.document.vector_value import VectorValue
from akasha.query.field_search import FieldSearchResult
from akasha.storage.field_catalog import load_field_catalog
from akasha.storage.point_store import PointStore
from akasha.storage.point_table import PointCommit
from akasha.compute.topk import BoundedTopK
from akasha.compute.dispatch import portable_simd_width
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
from akasha.compute.simd import _prepare_f32_query, _prepared_f32_score
from akasha.index.flat import SearchResult
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_rebuild import (
    build_hnsw as _build_hnsw,
    restore_hnsw_overlay,
    HnswRebuild,
    HNSW_REBUILD_ATTEMPTS,
    HNSW_REBUILD_CATCHUP_PASSES,
)
from akasha.index.hnsw_stats import HnswSearchStats, copy_search_stats
from akasha.query.control import QueryControl
from akasha.query.field_fusion import FieldQuery
from akasha.index.field_ivf import IvfOptions
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.index.metadata import MetadataIndex
from akasha.index.sparse import SparseElement, SparseIndex, validate_sparse
from akasha.query.executor import candidate_ordinals
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.index_evaluator import evaluate_all, evaluate_expression
from akasha.query.planner import QueryPlanner
from akasha.api.snapshot import ReadSnapshot
from akasha.storage.read_generation import (
    ReadGeneration,
    ReadGenerationCache,
    SEALED_RUN_LIMIT,
)
from akasha.storage.committed_compaction import (
    begin_compaction,
    build_compaction,
    COMPACTION_ATTEMPTS,
    CompactionInputs,
    CompactionOutput,
    finish_compaction,
)
from akasha.storage.compaction import (
    CompactionPolicy,
    LEVEL_ZERO_SEGMENT_LIMIT,
)
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.file_leases import reclaim_unreferenced_job_files
from akasha.storage.maintenance import (
    CompactionCounts,
    DEFAULT_MAINTENANCE_LIBRARY,
    MaintenanceController,
)
from akasha.storage.retired_files import RetiredFileQueue, reclaim_retired_batch
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
    sync_directory,
)
from akasha.storage.hnsw_store import (
    hnsw_snapshot_eligibility,
    hnsw_snapshot_max_bytes,
    try_open_compatible_hnsw_snapshot_view,
    try_read_compatible_hnsw_snapshot_owned,
)
from akasha.storage.hnsw_overlay_cache import (
    load_hnsw_overlay_cache,
    publish_hnsw_overlay_cache_best_effort,
)
from akasha.storage.hnsw_checkpoint import (
    migrate_hnsw_base_name,
    HnswCheckpoint,
    write_hnsw_checkpoint,
)
from akasha.storage.collection_config import (
    collection_config_exists,
    load_collection_config,
    publish_collection_config,
)
from akasha.storage.manifest import (
    load_manifest,
    hnsw_base_sequence,
    Manifest,
    publish_manifest,
    SegmentDescriptor,
)
from akasha.storage.lock import CollectionLock
from akasha.storage.legacy_recovery import preflight_legacy_authority
from akasha.storage.operations import (
    CheckpointCopy,
    copy_checkpoint,
    StorageInspection,
)
from akasha.storage.memtable import MemTable, MemTableEntry
from akasha.storage.segment import (
    SEGMENT_KIND_BASE,
    SEGMENT_KIND_DELTA,
    write_segment_v3,
)
from akasha.storage.sparse_store import (
    append_sparse_wal,
    latest_sparse_records,
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
    WalReader,
    repair_wal_tail,
    rotate_wal,
    WalRecord,
)
from std.math import isfinite
from std.collections import Dict
from std.memory import ArcPointer
from std.time import sleep
from std.utils import BlockingScopedLock, BlockingSpinLock


comptime _BACKPRESSURE_SLEEP_SECONDS = 0.001
"""Poll period of a write waiting for a sealed-run merge."""
comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct _ResolvedCollectionConfig(Movable):
    var config: CollectionConfig
    var needs_publication: Bool

    def __init__(out self, config: CollectionConfig, needs_publication: Bool):
        self.config = config.copy()
        self.needs_publication = needs_publication


struct PersistentCollection:
    """A durable, single-writer exact vector collection."""

    var path: String
    var dimension: Int
    var _path: String
    var _config: CollectionConfig
    var _wal_path: String
    var _memtable: MemTable
    var _point_store: Optional[PointStore]
    var _last_sequence: UInt64
    var _lock: Optional[ArcPointer[CollectionLock]]
    var _closed: Bool
    var _batch_failed: Bool
    var _hnsw: SegmentedHnsw
    var _hnsw_rebuild_lock: ArcPointer[BlockingSpinLock]
    var _hnsw_rebuild: Optional[ArcPointer[HnswRebuild]]
    var _hnsw_rebuild_delay_for_test: Float64
    var _hnsw_id_lookup: Optional[HnswIdOrdinalLookup]
    var _hnsw_id_lookup_dirty: Bool
    var _hnsw_id_lookup_builds: Int
    var _hnsw_available: Bool
    var _hnsw_unavailable_reason: String
    var _hnsw_mutations_since_rebuild: Int
    var _last_dense_plan_reason: String
    var _last_search_stats: HnswSearchStats
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
    var _read_generations: ArcPointer[ReadGenerationCache]
    var _maintenance: MaintenanceController
    var _cache_generation: UInt64
    var _source_checksum: UInt32
    var _hnsw_checkpoint_was_hit: Bool
    var _hnsw_base_sequence: UInt64
    var _hnsw_sidecar_max_bytes_for_test: UInt64
    var _overlay_cache_sequence: Optional[UInt64]
    var _overlay_cache_base_sequence: UInt64
    var _overlay_cache_base_checksum: UInt32
    var _hnsw_cache_was_hit: Bool
    var _metadata_cache_was_hit: Bool
    var _compaction_attempts: Int
    var _compaction_conflicts: Int
    var _backpressure_waits: Int
    """Calls that waited for a sealed-run merge or a background compaction."""

    def __init__(
        out self,
        path: String,
        config: CollectionConfig,
        var memtable: MemTable,
        last_sequence: UInt64,
        var lock: ArcPointer[CollectionLock],
        var hnsw: SegmentedHnsw,
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
        self._point_store = None
        self._last_sequence = last_sequence
        self._lock = Optional(lock^)
        self._closed = False
        self._batch_failed = False
        self._hnsw = hnsw^
        self._hnsw_rebuild_lock = ArcPointer(BlockingSpinLock())
        self._hnsw_rebuild = Optional[ArcPointer[HnswRebuild]]()
        self._hnsw_rebuild_delay_for_test = 0.0
        self._hnsw_id_lookup = Optional[HnswIdOrdinalLookup]()
        self._hnsw_id_lookup_dirty = metadata.slot_count() > 0
        self._hnsw_id_lookup_builds = 0
        self._hnsw_available = hnsw_available
        self._hnsw_unavailable_reason = "" if hnsw_available else String(
            copy=hnsw_unavailable_reason
        )
        self._hnsw_mutations_since_rebuild = 0
        self._last_dense_plan_reason = ""
        self._last_search_stats = HnswSearchStats()
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
        self._pins = ArcPointer(GenerationPinRegistry(path, config.dimension))
        self._retired = ArcPointer(RetiredFileQueue())
        self._writer_lock = ArcPointer(BlockingSpinLock())
        self._read_generations = ArcPointer(ReadGenerationCache())
        self._read_generations[].generation = cache_generation
        self._maintenance = MaintenanceController.start(
            path,
            config.dimension,
            self._writer_lock,
            self._pins,
            self._retired,
            self._read_generations,
            maintenance_library_path,
        )
        self._cache_generation = cache_generation
        self._source_checksum = source_checksum
        self._hnsw_checkpoint_was_hit = hnsw_checkpoint_hit
        self._hnsw_base_sequence = last_sequence
        self._hnsw_sidecar_max_bytes_for_test = hnsw_snapshot_max_bytes()
        self._overlay_cache_sequence = None
        self._overlay_cache_base_sequence = 0
        self._overlay_cache_base_checksum = 0
        self._hnsw_cache_was_hit = hnsw_cache_hit
        self._metadata_cache_was_hit = metadata_cache_hit
        self._compaction_attempts = 0
        self._compaction_conflicts = 0
        self._backpressure_waits = 0

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
        if collection_config_exists(path):
            var catalog = load_field_catalog(path)
            if catalog.format_version == 2:
                if catalog.field_at(0).hnsw.value() != requested:
                    raise Error(
                        "requested configuration differs from field catalog"
                    )
                return PersistentCollection.open_with_fields(
                    path,
                    catalog._fields.copy(),
                    maintenance_library_path=maintenance_library_path,
                )
        _ = ensure_durable_directory(path)
        var lock = CollectionLock.acquire(path + "/collection.lock")
        var resolved = _resolve_collection_config(path, requested)
        var config = resolved.config.copy()
        var dimension = config.dimension

        var recovered = preflight_legacy_authority(path, dimension)
        var snapshot_sequence = recovered.snapshot_sequence
        var cache_generation = recovered.generation
        var last_sequence = recovered.last_sequence
        var wal_valid_length = recovered.wal_valid_length
        var wal_source_length = recovered.wal_source_length
        var memtable = recovered.memtable.take()
        var sparse = recovered.sparse.take()
        var sparse_pending = recovered.sparse_pending.take()
        var sparse_wal = recovered.sparse_wal.take()
        var checkpoint_live_ids = recovered.checkpoint_live_ids.take()
        reclaim_unreferenced_job_files(path, dimension)

        var source_checksum = authoritative_index_checksum(memtable)
        var hnsw_load = _load_or_rebuild_hnsw(
            path,
            config,
            cache_generation,
            snapshot_sequence,
            last_sequence,
            source_checksum,
            checkpoint_live_ids,
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
        repair_wal_tail(path + "/wal.bin", wal_valid_length, wal_source_length)
        repair_sparse_wal_tail(path + "/sparse.wal", sparse_wal)

        var collection = PersistentCollection(
            path,
            config,
            memtable^,
            last_sequence,
            ArcPointer(lock^),
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
        if hnsw_load.base_sequence:
            collection._hnsw_base_sequence = hnsw_load.base_sequence.value()
        return collection^

    @staticmethod
    def open_with_fields(
        path: String,
        var fields: List[VectorFieldSpec],
        *,
        maintenance_library_path: String = DEFAULT_MAINTENANCE_LIBRARY,
    ) raises -> PersistentCollection:
        """Open or atomically migrate to the immutable typed field catalog."""
        var store = PointStore.open(path, fields^)
        var config = store._catalog[].field_at(0).hnsw.value().copy()
        var table = store._table.read_projection()
        var metadata = _build_metadata(table)
        var sparse = SparseIndex()
        for ordinal in table.live_ordinals():
            ref entry = table.entry_ref_at(ordinal)
            if entry.has_sparse() and len(entry.sparse()) > 0:
                sparse.upsert(entry.id, entry.sparse())
        var generation = (
            store._manifest.value().generation if store._manifest else UInt64(0)
        )
        var checkpoint_sequence = store._manifest.value().last_sequence if store._manifest else UInt64(
            0
        )
        var hnsw_load = _load_or_rebuild_hnsw(
            path,
            config,
            generation,
            checkpoint_sequence,
            store._table.last_sequence(),
            0,
            Dict[Int, Bool](),
            table,
            point_projection=True,
        )
        var available = hnsw_load.available
        var checkpoint_hit = hnsw_load.sidecar_hit
        var replayed = hnsw_load.replayed_mutations
        var hnsw = hnsw_load.take_index()
        var collection = PersistentCollection(
            path,
            config,
            table^,
            store._table.last_sequence(),
            store._lock.value().copy(),
            hnsw^,
            sparse^,
            [],
            metadata^,
            maintenance_library_path,
            generation,
            0,
            checkpoint_hit,
            False,
            False,
            available,
            "rebuild_failed",
        )
        collection._point_store = Optional(store^)
        collection._hnsw_mutations_since_rebuild = replayed
        if hnsw_load.base_sequence:
            collection._hnsw_base_sequence = hnsw_load.base_sequence.value()
        return collection^

    def _field_catalog(self) -> Optional[ArcPointer[FieldCatalog]]:
        if self._point_store:
            return Optional(self._point_store.value()._catalog.copy())
        return None

    def vector_fields(self) raises -> List[VectorFieldSpec]:
        """Return defensive schema descriptors, including reserved fields 0/1.
        """
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            if self._point_store:
                return self._point_store.value()._catalog[]._fields.copy()
            return legacy_vector_fields(self._config)

    def get_point(self, id: Int) raises -> Optional[PointState]:
        return self.snapshot().get_point(id)

    def search_field(
        mut self,
        name: String,
        query: VectorValue,
        k: Int,
        var expression: Optional[FilterExpression] = None,
        *,
        approximate: Bool = False,
        ef_search: Int = -1,
        rerank_k: Int = 0,
        ivf: Optional[IvfOptions] = None,
        control: Optional[QueryControl] = None,
    ) raises -> List[FieldSearchResult]:
        var execution = self.snapshot().search_field_reported(
            name,
            query,
            k,
            expression^,
            approximate=approximate,
            ef_search=ef_search,
            rerank_k=rerank_k,
            ivf=ivf,
            control=control,
        )
        with BlockingScopedLock(self._writer_lock[]):
            self._last_search_stats = copy_search_stats(execution.stats)
            self._last_dense_plan_reason = execution.reason.copy()
        return execution.take_results()

    def search_fields(
        mut self,
        queries: List[FieldQuery],
        k: Int,
        *,
        fetch_k: Int = 100,
        rank_constant: Int = 60,
        var expression: Optional[FilterExpression] = None,
        control: Optional[QueryControl] = None,
        rerank: Optional[FieldQuery] = None,
    ) raises -> List[FieldSearchResult]:
        var execution = self.snapshot().search_fields_reported(
            queries,
            k,
            fetch_k=fetch_k,
            rank_constant=rank_constant,
            expression=expression^,
            control=control,
            rerank=rerank,
        )
        with BlockingScopedLock(self._writer_lock[]):
            self._last_search_stats = copy_search_stats(execution.stats)
            self._last_dense_plan_reason = execution.reason.copy()
        return execution.take_results()

    def apply_point_batch(
        mut self, mutations: List[PointMutation]
    ) raises -> BatchWriteResult:
        var waited = False
        while True:
            with BlockingScopedLock(self._writer_lock[]):
                if self._write_admitted(waited):
                    var committed = self._apply_point_batch_unlocked(mutations)
                    return BatchWriteResult(
                        committed.first_sequence,
                        committed.last_sequence,
                        committed.mutation_count,
                    )
            waited = True
            sleep(_BACKPRESSURE_SLEEP_SECONDS)

    def _apply_point_batch_unlocked(
        mut self, mutations: List[PointMutation]
    ) raises -> PointCommit:
        self._ensure_open()
        if not self._point_store:
            raise Error("point mutations require a field-aware collection")
        var ids = List[Int]()
        var previous_dense = Dict[Int, Int]()
        for index in range(len(mutations)):
            var id = mutations[index].id
            if id in previous_dense:
                continue
            var ordinal = self._memtable.ordinal_for(id)
            previous_dense[id] = (
                self._memtable.entry_ref_at(ordinal).dense_address() if ordinal
                >= 0 else 0
            )
            ids.append(id)
        var committed = self._point_store.value().apply_batch(mutations)
        self._last_sequence = committed.last_sequence
        var metadata_slots = self._metadata.slot_count()
        try:
            for id in ids:
                var entry = MemTableEntry.from_point(
                    self._point_store.value()._table.entry(id)
                )
                self._memtable.put(entry^)
                ref current = self._memtable.entry_ref_at(
                    self._memtable.ordinal_for(id)
                )
                if current.tombstone:
                    self._metadata.delete(id)
                else:
                    self._metadata.upsert(id, clone_fields(current.fields()))
                if current.has_sparse() and len(current.sparse()) > 0:
                    self._sparse.upsert(id, current.sparse())
                else:
                    self._sparse.delete(id)
        except error:
            # Authority is committed. Refuse a partial derived read projection
            # until recovery reconstructs every field from that atomic envelope.
            self._point_store.value()._io_failed = True
            raise error^
        self._record_read_state(ids, committed.last_sequence)
        self._extend_hnsw_id_lookup(metadata_slots)
        for id in ids:
            var current = self._memtable.entry_ref_at(
                self._memtable.ordinal_for(id)
            ).dense_address()
            if current == previous_dense[id]:
                continue
            if current == 0:
                self._update_hnsw_after_delete(id, previous_dense[id] != 0)
            else:
                self._update_hnsw_after_upsert(id)
        self._invalidate_cache_hits()
        return committed

    def collection_config(self) -> CollectionConfig:
        """Return a defensive copy of this collection's durable identity."""
        return self._config.copy()

    def ann_metric(self) -> MetricKind:
        """Return the metric to which the future ANN graph is bound."""
        return self._config.ann_metric.copy()

    def close(mut self) raises:
        """Release this collection's single-writer ownership.

        New operations fail with "collection is closed"; acquired operations
        own their root and finish. Captured backups retain the file lock until
        their copy completes, excluding a replacement writer. The cached root
        is released outside the writer lock, so a last owner frees rows and
        device state there."""
        var released = Optional[ArcPointer[ReadGeneration]]()
        with BlockingScopedLock(self._writer_lock[]):
            if self._closed:
                return
            if self._read_generations[].root:
                released = Optional(self._read_generations[].root.take())
            self._read_generations[].reset()
            self._hnsw.close()
            self._maintenance.cancel()
            self._closed = True
        _ = released^
        var maintenance_error = String()
        try:
            self._maintenance.close()
        except error:
            maintenance_error = String(error)
        with BlockingScopedLock(self._writer_lock[]):
            if self._point_store:
                self._point_store.value().close()
            self._lock = None
        if maintenance_error.byte_length() > 0:
            raise Error(maintenance_error)

    def background_maintenance_enabled(self) -> Bool:
        return self._maintenance.enabled()

    def schedule_maintenance(mut self) raises -> Bool:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._maintenance.request_compaction()

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

    def last_search_stats(self) raises -> HnswSearchStats:
        """Return an owned copy of the most recent approximate-query stats."""
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return copy_search_stats(self._last_search_stats)

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

    def hnsw_id_lookup_incremental_append_count(self) raises -> Int:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            if not Bool(self._hnsw_id_lookup):
                return 0
            return self._hnsw_id_lookup.value().incremental_append_count()

    def snapshot(self) raises -> ReadSnapshot:
        """Capture an immutable owned view of all currently visible records."""
        with BlockingScopedLock(self._writer_lock[]):
            return self._snapshot_unlocked()

    def _snapshot_unlocked(self) raises -> ReadSnapshot:
        self._ensure_open()
        var generation = self._read_generations[].generation
        return ReadSnapshot(
            self._read_generations[].acquire(
                self._config,
                generation,
                self._last_sequence,
                self._memtable,
                self._pins,
                self._field_catalog(),
            )
        )

    def upsert(mut self, id: Int, var values: List[Float32]) raises:
        var waited = False
        while True:
            with BlockingScopedLock(self._writer_lock[]):
                if self._write_admitted(waited):
                    self._upsert_unlocked(id, values^)
                    return
            waited = True
            sleep(_BACKPRESSURE_SLEEP_SECONDS)

    def _upsert_unlocked(mut self, id: Int, var values: List[Float32]) raises:
        self._ensure_open()
        self._validate_vector(values)
        if self._point_store:
            var changes: List[PointMutation] = [
                PointMutation(
                    id,
                    1,
                    [
                        FieldUpdate.set(
                            0, VectorValue.dense[DType.float32](values^)
                        )
                    ],
                    Optional(List[DocumentField]()),
                )
            ]
            _ = self._apply_point_batch_unlocked(changes)
            return
        var metadata_slots = self._metadata.slot_count()
        var sequence = self._next_sequence()
        var wal_values = values.copy()
        var record = WalRecord.upsert(sequence, id, wal_values^)
        append_wal(self._wal_path, self._config.dimension, record)
        self._memtable.apply_upsert(id, sequence, values^)
        self._record_read_state([id], sequence)
        var metadata_fields = List[DocumentField]()
        self._metadata.upsert(id, metadata_fields^)
        self._last_sequence = sequence
        self._extend_hnsw_id_lookup(metadata_slots)
        self._update_hnsw_after_upsert(id)
        self._invalidate_cache_hits()

    def upsert_document(
        mut self,
        id: Int,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) raises:
        var waited = False
        while True:
            with BlockingScopedLock(self._writer_lock[]):
                if self._write_admitted(waited):
                    self._upsert_document_unlocked(id, values^, fields^)
                    return
            waited = True
            sleep(_BACKPRESSURE_SLEEP_SECONDS)

    def _upsert_document_unlocked(
        mut self,
        id: Int,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) raises:
        self._ensure_open()
        self._validate_vector(values)
        if self._point_store:
            var changes: List[PointMutation] = [
                PointMutation(
                    id,
                    1,
                    [
                        FieldUpdate.set(
                            0, VectorValue.dense[DType.float32](values^)
                        )
                    ],
                    Optional(fields^),
                )
            ]
            _ = self._apply_point_batch_unlocked(changes)
            return
        var metadata_slots = self._metadata.slot_count()
        var sequence = self._next_sequence()
        var wal_values = values.copy()
        var wal_fields = clone_fields(fields)
        var metadata_fields = clone_fields(fields)
        var record = WalRecord.document_upsert(
            sequence, id, wal_values^, wal_fields^
        )
        append_wal(self._wal_path, self._config.dimension, record)
        self._memtable.apply_document_upsert(id, sequence, values^, fields^)
        self._record_read_state([id], sequence)
        self._metadata.upsert(id, metadata_fields^)
        self._last_sequence = sequence
        self._extend_hnsw_id_lookup(metadata_slots)
        self._update_hnsw_after_upsert(id)
        self._invalidate_cache_hits()

    def apply_batch(
        mut self, mutations: List[BatchMutation]
    ) raises -> BatchWriteResult:
        """Validate and durably apply one all-or-nothing dense mutation batch.
        """
        var waited = False
        while True:
            with BlockingScopedLock(self._writer_lock[]):
                if self._write_admitted(waited):
                    return self._apply_batch_unlocked(mutations)
            waited = True
            sleep(_BACKPRESSURE_SLEEP_SECONDS)

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

        if self._point_store:
            var changes = List[PointMutation](capacity=len(mutations))
            for index in range(len(mutations)):
                ref mutation = mutations[index]
                if mutation.is_delete:
                    changes.append(PointMutation.delete(mutation.id))
                else:
                    changes.append(
                        PointMutation(
                            mutation.id,
                            1,
                            [
                                FieldUpdate.set(
                                    0,
                                    VectorValue.dense[DType.float32](
                                        mutation.values.copy()
                                    ),
                                )
                            ],
                            Optional(clone_fields(mutation.fields)),
                        )
                    )
            var committed = self._apply_point_batch_unlocked(changes)
            return BatchWriteResult(
                committed.first_sequence,
                committed.last_sequence,
                committed.mutation_count,
            )

        var prior_live_by_id = Dict[Int, Bool]()
        var first_sequence = self._last_sequence + 1
        var records = List[WalRecord](capacity=len(mutations))
        # Seed only affected IDs, preserving their other field owners. First
        # appearances define the slot order for IDs newly accepted by this batch.
        var staged_memtable = MemTable(self._config.dimension)
        var batch_ids = List[Int](capacity=len(mutations))
        for index in range(len(mutations)):
            var id = mutations[index].id
            if id not in prior_live_by_id:
                var ordinal = self._memtable.ordinal_for(id)
                prior_live_by_id[
                    id
                ] = ordinal >= 0 and self._memtable.is_live_at(ordinal)
                if ordinal >= 0:
                    staged_memtable.put(self._memtable.entry_at(ordinal))
                batch_ids.append(id)
            var sequence = first_sequence + UInt64(index)
            if mutations[index].is_delete:
                records.append(WalRecord.delete(sequence, mutations[index].id))
                staged_memtable.apply_delete(mutations[index].id, sequence)
                continue
            var wal_values = mutations[index].values.copy()
            var wal_fields = clone_fields(mutations[index].fields)
            records.append(
                WalRecord.document_upsert(
                    sequence,
                    mutations[index].id,
                    wal_values^,
                    wal_fields^,
                )
            )
            var staged_values = mutations[index].values.copy()
            var staged_fields = clone_fields(mutations[index].fields)
            staged_memtable.apply_document_upsert(
                mutations[index].id,
                sequence,
                staged_values^,
                staged_fields^,
            )
        # An append error may leave an accepted durable envelope. Block further
        # operations until recovery resolves it; publication errors follow the
        # same rule. Existing immutable roots remain usable.
        self._batch_failed = True
        append_wal_batch(self._wal_path, self._config.dimension, records)
        var metadata_slots = self._metadata.slot_count()
        if metadata_slots == 0:
            self._metadata.begin_bulk()
        for ordinal in range(staged_memtable.slot_count()):
            ref entry = staged_memtable.entry_ref_at(ordinal)
            if entry.tombstone:
                self._metadata.delete(entry.id)
            else:
                self._metadata.upsert(entry.id, clone_fields(entry.fields()))
            self._memtable.put(entry.clone())
        if metadata_slots == 0:
            self._metadata.finish_bulk()
        # One envelope: every final state enters the publisher before any
        # capture can run, so readers see all of the batch or none of it.
        self._record_read_state(
            batch_ids, first_sequence + UInt64(len(mutations) - 1)
        )
        self._extend_hnsw_id_lookup(metadata_slots)
        for index in range(len(mutations)):
            if mutations[index].is_delete:
                self._delete_sparse_field(
                    mutations[index].id, first_sequence + UInt64(index)
                )
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
        self._batch_failed = False
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
        var waited = False
        while True:
            with BlockingScopedLock(self._writer_lock[]):
                if self._write_admitted(waited):
                    self._upsert_sparse_unlocked(id, elements)
                    return
            waited = True
            sleep(_BACKPRESSURE_SLEEP_SECONDS)

    def _upsert_sparse_unlocked(
        mut self, id: Int, elements: List[SparseElement]
    ) raises:
        self._ensure_open()
        validate_sparse(elements)
        var ordinal = self._memtable.ordinal_for(id)
        if ordinal < 0 or not self._memtable.is_live_at(ordinal):
            raise Error("sparse vectors require an existing live point")
        if self._point_store:
            var changes: List[PointMutation] = [
                PointMutation(
                    id,
                    3,
                    [FieldUpdate.set(1, VectorValue.sparse(elements.copy()))],
                )
            ]
            _ = self._apply_point_batch_unlocked(changes)
            return
        var sequence = self._next_sequence()
        var wal_elements = elements.copy()
        var record = SparseWalRecord.upsert(sequence, id, wal_elements^)
        append_sparse_wal(self._sparse_wal_path, record)
        self._sparse.upsert(id, elements)
        self._memtable.set_sparse(id, elements.copy())
        self._sparse_pending.append(record.clone())
        self._last_sequence = sequence
        self._record_read_state([id], sequence)
        self._invalidate_cache_hits()

    def delete(mut self, id: Int) raises:
        var waited = False
        while True:
            with BlockingScopedLock(self._writer_lock[]):
                if self._write_admitted(waited):
                    self._delete_unlocked(id)
                    return
            waited = True
            sleep(_BACKPRESSURE_SLEEP_SECONDS)

    def _write_admitted(mut self, waited: Bool) raises -> Bool:
        """Admit a write unless sealed runs reached the limit.

        The caller holds the writer lock. Like a RocksDB write stall, a held
        write sleeps without the lock until the background merge publishes;
        close or a maintenance failure ends the wait through `_ensure_open`.
        One admitted batch may still seal up to 64 runs past the limit.
        """
        self._ensure_open()
        if self._read_generations[].sealed_count() < SEALED_RUN_LIMIT:
            return True
        if not waited:
            self._backpressure_waits += 1
        self._maintenance.request_merge()
        return False

    def _record_read_state(mut self, ids: List[Int], sequence: UInt64):
        """Record committed states for readers; start a due run merge.

        The worker merges outside the writer lock. Without one the merge runs
        here; it cannot reject the committed write, so a failure drops the
        derived state instead.
        """
        if self._hnsw_rebuild:
            self._hnsw_rebuild.value()[].record(self._memtable, ids, sequence)
        self._read_generations[].record(self._memtable, ids, sequence)
        if not self._read_generations[].merge_due():
            return
        if self._maintenance.enabled():
            self._maintenance.request_merge()
            return
        try:
            self._read_generations[].merge_sealed_runs()
        except:
            self._read_generations[].reset()

    def _delete_unlocked(mut self, id: Int) raises:
        self._ensure_open()
        if self._point_store:
            var changes: List[PointMutation] = [PointMutation.delete(id)]
            _ = self._apply_point_batch_unlocked(changes)
            return
        var metadata_slots = self._metadata.slot_count()
        var metadata_ordinal = self._metadata.ordinal_for(id)
        var was_live = metadata_ordinal >= 0 and self._metadata.is_live_at(
            metadata_ordinal
        )
        var sequence = self._next_sequence()
        var record = WalRecord.delete(sequence, id)
        append_wal(self._wal_path, self._config.dimension, record)
        self._memtable.apply_delete(id, sequence)
        self._record_read_state([id], sequence)
        self._metadata.delete(id)
        self._delete_sparse_field(id, sequence)
        self._last_sequence = sequence
        self._extend_hnsw_id_lookup(metadata_slots)
        self._update_hnsw_after_delete(id, was_live)
        self._invalidate_cache_hits()

    def _delete_sparse_field(mut self, id: Int, sequence: UInt64):
        """Drop a deleted point's sparse field.

        The dense WAL delete is its durable record; recovery replays it with
        the sparse WAL. Pending it makes the next sparse delta segment carry
        the delete, so a later reinsert cannot resurrect the older field.
        """
        if not self._sparse.contains(id):
            return
        self._sparse.delete(id)
        self._sparse_pending.append(SparseWalRecord.delete(sequence, id))

    def search_dot(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        return self.snapshot().search_dot(query, k)

    def search_l2(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        return self.snapshot().search_l2(query, k)

    def search_cosine(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        return self.snapshot().search_cosine(query, k)

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

    def search_device_dot_batch[
        use_accelerator: Bool
    ](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var snapshot = self.snapshot()
        return snapshot.search_device_dot_batch[use_accelerator](
            queries, k, options
        )

    def search_device_l2_batch[
        use_accelerator: Bool
    ](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var snapshot = self.snapshot()
        return snapshot.search_device_l2_batch[use_accelerator](
            queries, k, options
        )

    def search_device_cosine_batch[
        use_accelerator: Bool
    ](
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

    def search_device_dot_where_batch[
        use_accelerator: Bool
    ](
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

    def search_device_l2_where_batch[
        use_accelerator: Bool
    ](
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

    def search_device_cosine_where_batch[
        use_accelerator: Bool
    ](
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
            return self._search_approx_unlocked(query, k, ef_search, _L2_METRIC)

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
        self._validate_query(query, k)
        for index in range(len(conditions)):
            conditions[index].validate()
        return self.snapshot().search_dot_filtered(query, k, conditions)

    def search_l2_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        for index in range(len(conditions)):
            conditions[index].validate()
        return self.snapshot().search_l2_filtered(query, k, conditions)

    def search_cosine_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        for index in range(len(conditions)):
            conditions[index].validate()
        return self.snapshot().search_cosine_filtered(query, k, conditions)

    def search_dot_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        expression.validate()
        return self.snapshot().search_dot_where(query, k, expression)

    def search_l2_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        expression.validate()
        return self.snapshot().search_l2_where(query, k, expression)

    def search_cosine_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        expression.validate()
        return self.snapshot().search_cosine_where(query, k, expression)

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
        return self.snapshot().search_sparse_dot(query, k)

    def search_sparse_dot_where(
        self,
        query: List[SparseElement],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        validate_sparse(query)
        if k <= 0:
            raise Error("k must be positive")
        expression.validate()
        return self.snapshot().search_sparse_dot_where(query, k, expression)

    def search_hybrid_dot(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int = 60,
    ) raises -> List[SearchResult]:
        self._validate_hybrid(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )
        return self.snapshot().search_hybrid_dot(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )

    def search_hybrid_l2(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int = 60,
    ) raises -> List[SearchResult]:
        self._validate_hybrid(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )
        return self.snapshot().search_hybrid_l2(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )

    def search_hybrid_cosine(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int = 60,
    ) raises -> List[SearchResult]:
        self._validate_hybrid(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )
        return self.snapshot().search_hybrid_cosine(
            dense_query, sparse_query, k, fetch_k, rank_constant
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
        self._validate_hybrid(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )
        expression.validate()
        return self.snapshot().search_hybrid_dot_where(
            dense_query, sparse_query, k, fetch_k, rank_constant, expression
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
        self._validate_hybrid(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )
        expression.validate()
        return self.snapshot().search_hybrid_l2_where(
            dense_query, sparse_query, k, fetch_k, rank_constant, expression
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
        self._validate_hybrid(
            dense_query, sparse_query, k, fetch_k, rank_constant
        )
        expression.validate()
        return self.snapshot().search_hybrid_cosine_where(
            dense_query, sparse_query, k, fetch_k, rank_constant, expression
        )

    def flush(mut self) raises:
        """Atomically append an immutable incremental checkpoint."""
        self._prepare_hnsw_checkpoint()
        var waited = False
        var inline_compaction: Bool
        while True:
            with BlockingScopedLock(self._writer_lock[]):
                if self._flush_admitted(waited):
                    inline_compaction = self._flush_unlocked()
                    break
            waited = True
            sleep(_BACKPRESSURE_SLEEP_SECONDS)
        if inline_compaction:
            self.compact()

    def rebuild_hnsw(mut self) raises:
        """Build from a pinned root while writes continue; catch up and publish.

        Job admission precedes writer locking. An overflowed journal retries
        from a newer root, at most four times, without replacing a valid graph.
        """
        self._rebuild_hnsw(only_if_due=False)

    def _rebuild_hnsw(mut self, *, only_if_due: Bool) raises:
        with BlockingScopedLock(self._hnsw_rebuild_lock[]):
            if only_if_due:
                with BlockingScopedLock(self._writer_lock[]):
                    self._ensure_open()
                    if not self._hnsw_requires_maintenance():
                        return
            for _ in range(HNSW_REBUILD_ATTEMPTS):
                var job = self._begin_hnsw_rebuild()
                try:
                    var candidate = job[].build()
                    if self._finish_hnsw_rebuild(job, candidate^):
                        return
                except error:
                    self._cancel_hnsw_rebuild(job)
                    raise error^
        raise Error("HNSW rebuild retry budget exhausted")

    def _begin_hnsw_rebuild(mut self) raises -> ArcPointer[HnswRebuild]:
        """Capture and register under writer; caller serializes build jobs."""
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            if self._hnsw_rebuild:
                raise Error("HNSW rebuild already active")
            try:
                var root = self._read_generations[].acquire(
                    self._config,
                    self._read_generations[].generation,
                    self._last_sequence,
                    self._memtable,
                    self._pins,
                    self._field_catalog(),
                )
                var job = ArcPointer(HnswRebuild(root^))
                job[].delay_for_test = self._hnsw_rebuild_delay_for_test
                self._hnsw_rebuild = Optional(job.copy())
                return job^
            except error:
                if self._config != self._hnsw.config:
                    self._mark_hnsw_unavailable("rebuild_failed")
                raise error^

    def _cancel_hnsw_rebuild(mut self, job: ArcPointer[HnswRebuild]):
        with BlockingScopedLock(self._writer_lock[]):
            if self._hnsw_rebuild and self._hnsw_rebuild.value() is job:
                self._hnsw_rebuild = None

    def _finish_hnsw_rebuild(
        mut self, job: ArcPointer[HnswRebuild], var candidate: SegmentedHnsw
    ) raises -> Bool:
        """Rotate and apply bounded journals outside writer, then swap graphs.

        Publication requires an empty journal with complete source coverage.
        The old graph is also released outside writer; no all-row scan, graph
        update, validation or source-map reconstruction occurs under that lock.
        """
        var staged = Optional(candidate^)
        try:
            for catchup_pass in range(HNSW_REBUILD_CATCHUP_PASSES + 1):
                var released = Optional[SegmentedHnsw]()
                var tail = Optional[MemTable]()
                with BlockingScopedLock(self._writer_lock[]):
                    if not self._hnsw_rebuild or not (
                        self._hnsw_rebuild.value() is job
                    ):
                        return False
                    self._ensure_open()
                    if (
                        job[].invalid
                        or job[].sequence != self._last_sequence
                        or job[].root[].config != self._config
                        or staged.value().config != self._config
                    ):
                        self._hnsw_rebuild = None
                        return False
                    if job[].tail.slot_count() == 0:
                        if (
                            staged.value().current_point_count()
                            != self._memtable.dense_live_count()
                        ):
                            raise Error(
                                "HNSW rebuild catch-up live count mismatch"
                            )
                        released = Optional(self._hnsw^)
                        self._hnsw = staged.take()
                        self._hnsw_base_sequence = job[].root[].sequence
                        self._hnsw_available = True
                        self._hnsw_unavailable_reason = ""
                        self._hnsw_mutations_since_rebuild = (
                            self._hnsw.mutation_count()
                        )
                        self._hnsw_checkpoint_was_hit = False
                        self._hnsw_cache_was_hit = False
                        self._hnsw_rebuild = None
                    elif catchup_pass == HNSW_REBUILD_CATCHUP_PASSES:
                        self._hnsw_rebuild = None
                        return False
                    else:
                        tail = Optional(job[].take_tail())
                if released:
                    _ = released.take()
                    return True
                job[].catch_up(tail.value(), staged.value())
        except error:
            self._cancel_hnsw_rebuild(job)
            raise error^
        return False

    def backup_to(mut self, target: String) raises -> StorageInspection:
        """Checkpoint, then copy that generation without the writer lock.

        Like a RocksDB backup, the copy holds a lease on the captured files
        instead of the lock; writes, flushes and compactions continue.
        """
        var checkpoint = self._begin_backup()
        try:
            copy_checkpoint(self._path, target, checkpoint)
        except error:
            self._end_backup(checkpoint)
            raise error^
        self._end_backup(checkpoint)
        return checkpoint.report.copy()

    def _begin_backup(mut self) raises -> CheckpointCopy:
        """Checkpoint, then capture and pin the committed generation."""
        self._prepare_hnsw_checkpoint()
        var waited = False
        var inline_compaction: Bool
        var captured: CheckpointCopy
        while True:
            with BlockingScopedLock(self._writer_lock[]):
                if self._flush_admitted(waited):
                    inline_compaction = self._flush_unlocked()
                    var checkpoint = CheckpointCopy(
                        load_manifest(self._path, self._config.dimension),
                        Optional(self._config.copy()),
                        self._memtable.live_count(),
                        source_lock=self._lock.copy(),
                        catalog=self._field_catalog(),
                    )
                    self._pins[].pin(checkpoint.manifest.generation)
                    captured = checkpoint^
                    break
            waited = True
            sleep(_BACKPRESSURE_SLEEP_SECONDS)
        # The captured files are pinned even if synchronous maintenance
        # replaces them before the backup starts copying.
        if inline_compaction:
            try:
                self.compact()
            except error:
                self._end_backup(captured)
                raise error^
        return captured^

    def _end_backup(self, mut checkpoint: CheckpointCopy):
        """Release the capture, reclaiming obsolete files on the last lease."""
        self._pins[].unpin(checkpoint.manifest.generation)
        checkpoint._source_lock = None

    def _flush_admitted(mut self, waited: Bool) raises -> Bool:
        """Admit a flush unless level-zero segments reached the limit.

        The caller holds the writer lock. Like a RocksDB level-zero stop, a held
        flush sleeps without the lock until the background compaction
        publishes; close or a maintenance failure ends the wait through
        `_ensure_open`. Without a worker, a flush compacts inline at the policy
        threshold and never reaches the limit.
        """
        self._ensure_open()
        if not self._maintenance.enabled() or not path_exists(
            self._path + "/manifest.bin"
        ):
            return True
        var manifest = load_manifest(self._path, self._config.dimension)
        var policy = CompactionPolicy(LEVEL_ZERO_SEGMENT_LIMIT)
        if not policy.should_compact(manifest):
            return True
        if not waited:
            self._backpressure_waits += 1
        _ = self._maintenance.request_compaction()
        return False

    def _flush_unlocked(mut self) raises -> Bool:
        """Checkpoint and schedule; True asks the caller to compact unlocked."""
        var published = self._checkpoint_unlocked()
        if published and CompactionPolicy(4).should_compact(published.value()):
            if self._maintenance.enabled():
                _ = self._maintenance.request_compaction()
            else:
                return True
        return False

    def _checkpoint_unlocked(mut self) raises -> Optional[Manifest]:
        """Checkpoint the WAL tail; returns the manifest when one was added."""
        self._ensure_open()
        if self._point_store:
            var previous = self._read_generations[].generation
            var generation = previous + 1
            if path_exists(self._path + "/manifest.bin"):
                var current = load_manifest(self._path, self._config.dimension)
                if current.generation == UInt64.MAX:
                    raise Error("manifest generation exhausted")
                generation = current.generation + 1
            self._ensure_owned_hnsw_checkpoint()
            var checkpoint = Optional[HnswCheckpoint]()
            if (
                self._hnsw_available
                and self._hnsw.base_is_owned()
                and not self._hnsw_checkpoint_was_hit
            ):
                var eligibility = hnsw_snapshot_eligibility(
                    self._hnsw.immutable_owned_base(),
                    self._hnsw_sidecar_max_bytes_for_test,
                )
                if not eligibility.graph_usable:
                    self._mark_hnsw_unavailable("eligibility_failed")
                if eligibility.eligible:
                    checkpoint = Optional(
                        write_hnsw_checkpoint(
                            self._path,
                            self._hnsw.immutable_owned_base(),
                            self._hnsw_base_sequence,
                            generation,
                        )
                    )
            self._point_store.value().flush(checkpoint^)
            var manifest = load_manifest(self._path, self._config.dimension)
            self._hnsw_checkpoint_was_hit = (
                self._point_store.value()._hnsw_reference_valid
            )
            self._read_generations[].publish(manifest.generation)
            self._publish_index_caches_best_effort()
            if previous == manifest.generation:
                return None
            return Optional(manifest^)
        self._reclaim_retired()
        var previous_sequence = UInt64(0)
        var generation = UInt64(1)
        var has_previous_manifest = False
        var previous_hnsw_name = String()
        var retained_hnsw = Optional[Manifest]()
        var migrated_hnsw_name = Optional[String]()
        var retain_previous_hnsw = False
        var previous_hnsw_metadata_matches = False
        var descriptors = List[SegmentDescriptor]()
        if path_exists(self._path + "/manifest.bin"):
            var previous_manifest = load_manifest(
                self._path, self._config.dimension
            )
            previous_sequence = previous_manifest.last_sequence
            has_previous_manifest = True
            if Bool(previous_manifest.hnsw_name):
                previous_hnsw_name = previous_manifest.hnsw_name.value().copy()
                previous_hnsw_metadata_matches = (
                    self._hnsw_checkpoint_was_hit
                    and previous_manifest.hnsw_config_fingerprint.value()
                    == self._config.fingerprint()
                    and previous_manifest.hnsw_point_count.value()
                    == UInt64(self._hnsw.current_point_count())
                    and path_exists(self._path + "/" + previous_hnsw_name)
                )
                if (
                    self._hnsw_checkpoint_was_hit
                    and previous_manifest.format_version >= 4
                    and previous_manifest.hnsw_config_fingerprint.value()
                    == self._config.fingerprint()
                    and path_exists(self._path + "/" + previous_hnsw_name)
                ):
                    retain_previous_hnsw = True
            if self._last_sequence < previous_sequence:
                raise Error("collection sequence precedes checkpoint")
            if previous_manifest.format_version >= 2:
                if previous_manifest.generation == UInt64.MAX:
                    raise Error("manifest generation exhausted")
                generation = previous_manifest.generation + 1
            if (
                self._hnsw_checkpoint_was_hit
                and previous_manifest.format_version == 3
                and previous_manifest.hnsw_name
                and self._last_sequence > previous_sequence
                and previous_manifest.hnsw_config_fingerprint.value()
                == self._config.fingerprint()
                and path_exists(self._path + "/" + previous_hnsw_name)
            ):
                migrated_hnsw_name = Optional(
                    migrate_hnsw_base_name(
                        self._path, previous_manifest, generation
                    )
                )
                retain_previous_hnsw = True
            for index in range(len(previous_manifest.segments)):
                descriptors.append(previous_manifest.segments[index].clone())
            if retain_previous_hnsw:
                retained_hnsw = Optional(previous_manifest^)

        # Full graph maintenance runs before checkpoint admission, outside
        # writer. A first delta-only graph can still transfer its ownership.
        self._ensure_owned_hnsw_checkpoint()
        if has_previous_manifest and self._last_sequence == previous_sequence:
            var hnsw_to_cleanup = String()
            if not previous_hnsw_metadata_matches and not retained_hnsw:
                var wrote_hnsw = False
                if self._hnsw_available:
                    self._ensure_owned_hnsw_checkpoint()
                    if self._hnsw_available and self._hnsw.base_is_owned():
                        var eligibility = hnsw_snapshot_eligibility(
                            self._hnsw.immutable_owned_base(),
                            self._hnsw_sidecar_max_bytes_for_test,
                        )
                        if not eligibility.graph_usable:
                            self._mark_hnsw_unavailable("eligibility_failed")
                        if eligibility.eligible:
                            var checkpoint = write_hnsw_checkpoint(
                                self._path,
                                self._hnsw.immutable_owned_base(),
                                self._hnsw_base_sequence,
                                generation,
                            )
                            var upgraded = Manifest.with_hnsw(
                                self._config.dimension,
                                generation,
                                self._last_sequence,
                                _clone_segment_descriptors(descriptors),
                                checkpoint.name,
                                checkpoint.info.checksum,
                                checkpoint.info.config_fingerprint,
                                checkpoint.info.live_point_count,
                                format_version=4 if checkpoint.info.sequence
                                == self._last_sequence else 5,
                            )
                            publish_manifest(self._path, upgraded)
                            self._read_generations[].publish(
                                upgraded.generation
                            )
                            self._hnsw_checkpoint_was_hit = True
                            wrote_hnsw = True
                            hnsw_to_cleanup = previous_hnsw_name.copy()
                if not wrote_hnsw and previous_hnsw_name.byte_length() > 0:
                    var downgraded = Manifest.with_segments(
                        self._config.dimension,
                        generation,
                        self._last_sequence,
                        _clone_segment_descriptors(descriptors),
                    )
                    publish_manifest(self._path, downgraded)
                    self._read_generations[].publish(downgraded.generation)
                    self._hnsw_checkpoint_was_hit = False
                    hnsw_to_cleanup = previous_hnsw_name.copy()
            rotate_wal(self._path)
            rotate_sparse_wal(self._path)
            if hnsw_to_cleanup.byte_length() > 0:
                self._retired[].retire_or_reclaim(
                    self._path,
                    [self._path + "/" + hnsw_to_cleanup],
                )
            self._sparse_pending = List[SparseWalRecord]()
            self._publish_index_caches_best_effort()
            return None

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
        var entries: List[MemTableEntry]
        if has_previous_manifest:
            kind = SEGMENT_KIND_DELTA
            level = 0
            min_sequence = previous_sequence + 1
            segment_prefix = "segment-delta-"
            entries = self._memtable.entries_after(previous_sequence)
        else:
            entries = self._memtable.live_entries()
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
        var hnsw_checkpoint = Optional[HnswCheckpoint]()
        if (
            self._hnsw_available
            and self._hnsw.base_is_owned()
            and not retained_hnsw
        ):
            var eligibility = hnsw_snapshot_eligibility(
                self._hnsw.immutable_owned_base(),
                self._hnsw_sidecar_max_bytes_for_test,
            )
            if not eligibility.graph_usable:
                self._mark_hnsw_unavailable("eligibility_failed")
            if eligibility.eligible:
                hnsw_checkpoint = Optional(
                    write_hnsw_checkpoint(
                        self._path,
                        self._hnsw.immutable_owned_base(),
                        self._hnsw_base_sequence,
                        generation,
                    )
                )

        # Every immutable data file is durable before the manifest commit
        # point. One directory barrier covers all completed renames.
        atomic_replace(sparse_temporary, self._path + "/" + sparse_name)
        atomic_replace(temporary_path, final_path)
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
        if hnsw_checkpoint:
            manifest = Manifest.with_hnsw(
                self._config.dimension,
                generation,
                self._last_sequence,
                descriptors^,
                hnsw_checkpoint.value().name,
                hnsw_checkpoint.value().info.checksum,
                hnsw_checkpoint.value().info.config_fingerprint,
                hnsw_checkpoint.value().info.live_point_count,
                format_version=4 if hnsw_checkpoint.value().info.sequence
                == self._last_sequence else 5,
            )
        elif retained_hnsw:
            ref retained = retained_hnsw.value()
            manifest = Manifest.with_hnsw(
                self._config.dimension,
                generation,
                self._last_sequence,
                descriptors^,
                migrated_hnsw_name.value() if migrated_hnsw_name else retained.hnsw_name.value(),
                retained.hnsw_checksum.value(),
                retained.hnsw_config_fingerprint.value(),
                retained.hnsw_point_count.value(),
                format_version=5,
            )
        else:
            manifest = Manifest.with_segments(
                self._config.dimension,
                generation,
                self._last_sequence,
                descriptors^,
            )
        publish_manifest(self._path, manifest)
        self._read_generations[].publish(manifest.generation)
        self._hnsw_checkpoint_was_hit = Bool(hnsw_checkpoint) or Bool(
            retained_hnsw
        )
        rotate_wal(self._path)
        rotate_sparse_wal(self._path)
        self._sparse_pending = List[SparseWalRecord]()
        if previous_hnsw_name.byte_length() > 0 and (
            not manifest.hnsw_name
            or manifest.hnsw_name.value() != previous_hnsw_name
        ):
            self._retired[].retire_or_reclaim(
                self._path,
                [self._path + "/" + previous_hnsw_name],
            )
        self._publish_index_caches_best_effort()
        return manifest^

    def compact(mut self) raises:
        """Replace the committed segment set with one complete live base.

        The merge runs without the writer lock; writes and flushes continue
        meanwhile. A separate job lock prevents competing full compactions.
        The publish rebases onto segments flushed during the build;
        a job whose inputs another publish replaced is discarded and retried
        from the new state, a bounded number of times.
        """
        with BlockingScopedLock(self._maintenance.compaction_lock[]):
            self._compact_exclusive()

    def _compact_exclusive(mut self) raises:
        """Run under the compaction lock, acquiring writer only at boundaries.
        """
        for _ in range(COMPACTION_ATTEMPTS):
            var inputs = self._begin_compaction()
            if not inputs:
                return
            var output = self._build_compaction(inputs.value())
            if self._finish_compaction(inputs.value(), output):
                return
        raise Error("compaction retry budget exhausted")

    def _begin_compaction(mut self) raises -> Optional[CompactionInputs]:
        """Checkpoint, then capture and pin the committed inputs."""
        self._prepare_hnsw_checkpoint()
        with BlockingScopedLock(self._writer_lock[]):
            _ = self._checkpoint_unlocked()
            var inputs = begin_compaction(
                self._path,
                self._config.dimension,
                self._pins,
                source_lock=self._lock.copy(),
            )
            if inputs:
                self._compaction_attempts += 1
            return inputs^

    def _build_compaction(
        self, mut inputs: CompactionInputs
    ) raises -> CompactionOutput:
        """Merge the pinned inputs into new files without the writer lock."""
        return build_compaction(
            self._path, self._config.dimension, inputs, self._pins
        )

    def _finish_compaction(
        mut self, mut inputs: CompactionInputs, output: CompactionOutput
    ) raises -> Bool:
        """Rebase and publish; False when the inputs were replaced."""
        var source_lock = inputs.source_lock
        with BlockingScopedLock(self._writer_lock[]):
            try:
                self._ensure_open()
            except error:
                _ = finish_compaction(
                    self._path,
                    self._config.dimension,
                    inputs,
                    output,
                    True,
                    self._pins,
                    self._retired,
                    self._read_generations,
                )
                raise error^
            if not finish_compaction(
                self._path,
                self._config.dimension,
                inputs,
                output,
                False,
                self._pins,
                self._retired,
                self._read_generations,
            ):
                self._compaction_conflicts += 1
                return False
            self._publish_index_caches_best_effort()
        reclaim_retired_batch(self._path, self._retired, self._writer_lock)
        # Prevent early owner destruction before the detached I/O completes.
        _ = source_lock^
        return True

    def compaction_attempts(self) raises -> Int:
        """Foreground compaction jobs that captured inputs."""
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._compaction_attempts

    def compaction_conflicts(self) raises -> Int:
        """Foreground compaction jobs discarded because their inputs were
        replaced by another publish."""
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._compaction_conflicts

    def background_compaction_counts(mut self) raises -> CompactionCounts:
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            return self._maintenance.compaction_counts()

    def maintenance(mut self) raises -> Bool:
        """Run synchronous compaction when the default L0 threshold is met."""
        self._prepare_hnsw_checkpoint()
        with BlockingScopedLock(self._maintenance.compaction_lock[]):
            with BlockingScopedLock(self._writer_lock[]):
                _ = self._checkpoint_unlocked()
                if not path_exists(self._path + "/manifest.bin"):
                    return False
                var manifest = load_manifest(self._path, self._config.dimension)
                if not CompactionPolicy(4).should_compact(manifest):
                    return False
            self._compact_exclusive()
            return True

    def _reclaim_retired(mut self) raises:
        self._retired[].reclaim(self._path)

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
        var count = self._memtable.dense_live_count()
        var plan = QueryPlanner.plan_dense(
            count,
            count,
            k,
            ef_search,
            self._config.max_ef_search,
            False,
            self._metric_compatible(metric),
            self._hnsw_available,
            dimension=self._config.dimension,
            m0=self._config.m0,
            metric=metric,
        )
        self._last_dense_plan_reason = plan.reason.copy()
        if not plan.use_hnsw:
            var conditions = List[FilterCondition]()
            var exact = self._search_filtered(query, k, metric, conditions)
            self._record_exact_fallback_stats(
                metric,
                ef_search,
                plan.initial_ef,
                count,
                len(exact),
                plan.reason,
            )
            return exact^
        if not self._ensure_hnsw_id_lookup():
            self._last_dense_plan_reason = "graph_unavailable"
            var conditions = List[FilterCondition]()
            var exact = self._search_filtered(query, k, metric, conditions)
            self._record_exact_fallback_stats(
                metric,
                ef_search,
                plan.initial_ef,
                count,
                len(exact),
                "graph_unavailable",
            )
            return exact^
        try:
            var candidates = self._hnsw.search(
                query,
                k,
                plan.initial_ef,
                self._memtable,
                self._hnsw_id_lookup.value(),
            )
            var segmented_stats = self._hnsw.last_search_stats()
            self._last_search_stats = copy_search_stats(segmented_stats)
            if segmented_stats.fallback_reason != "":
                self._last_dense_plan_reason = (
                    segmented_stats.fallback_reason.copy()
                )
            var allowed = Optional[Bitmap]()
            var expected_count = k
            if expected_count > count:
                expected_count = count
            return self._finish_hnsw_candidates(
                query,
                k,
                metric,
                candidates^,
                expected_count,
                allowed,
            )
        except:
            var conditions = List[FilterCondition]()
            var exact = self._search_filtered(query, k, metric, conditions)
            self._mark_hnsw_unavailable("search_failed")
            self._last_dense_plan_reason = "graph_unavailable"
            self._record_exact_fallback_stats(
                metric,
                ef_search,
                plan.initial_ef,
                count,
                len(exact),
                "graph_unavailable",
            )
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
        if self._memtable.dense_live_count() != self._memtable.live_count():
            for ordinal in matched.set_ordinals():
                if not self._memtable.entry_ref_at(ordinal).has_dense():
                    matched.clear(ordinal)
        var matched_count = matched.count()
        var total_count = self._memtable.dense_live_count()
        var plan = QueryPlanner.plan_dense(
            total_count,
            matched_count,
            k,
            ef_search,
            self._config.max_ef_search,
            True,
            self._metric_compatible(metric),
            self._hnsw_available,
            dimension=self._config.dimension,
            m0=self._config.m0,
            metric=metric,
        )
        self._last_dense_plan_reason = plan.reason.copy()
        if not plan.use_hnsw:
            var exact = self._search_candidates(query, k, metric, matched)
            self._record_exact_fallback_stats(
                metric,
                ef_search,
                plan.initial_ef,
                matched_count,
                len(exact),
                plan.reason,
            )
            return exact^
        if not self._ensure_hnsw_id_lookup():
            self._last_dense_plan_reason = "graph_unavailable"
            var exact = self._search_candidates(query, k, metric, matched)
            self._record_exact_fallback_stats(
                metric,
                ef_search,
                plan.initial_ef,
                matched_count,
                len(exact),
                "graph_unavailable",
            )
            return exact^
        try:
            var allowed_bitmap = matched.clone()
            var eligibility = HnswEligibility(
                matched^, self._hnsw_id_lookup.value()
            )
            var candidates = self._hnsw.search_allowed(
                query,
                k,
                plan.initial_ef,
                plan.max_ef,
                eligibility,
                self._memtable,
                self._hnsw_id_lookup.value(),
            )
            var segmented_stats = self._hnsw.last_search_stats()
            self._last_search_stats = copy_search_stats(segmented_stats)
            if segmented_stats.fallback_reason != "":
                self._last_dense_plan_reason = (
                    segmented_stats.fallback_reason.copy()
                )
            var allowed = Optional(allowed_bitmap^)
            var expected_count = k
            if expected_count > matched_count:
                expected_count = matched_count
            return self._finish_hnsw_candidates(
                query,
                k,
                metric,
                candidates^,
                expected_count,
                allowed,
            )
        except:
            var exact = self._search_where(query, k, metric, expression)
            self._mark_hnsw_unavailable("search_failed")
            self._last_dense_plan_reason = "graph_unavailable"
            self._record_exact_fallback_stats(
                metric,
                ef_search,
                plan.initial_ef,
                matched_count,
                len(exact),
                "graph_unavailable",
            )
            return exact^

    def _record_exact_fallback_stats(
        mut self,
        metric: Int,
        requested_ef: Int,
        effective_ef: Int,
        visited: Int,
        retained: Int,
        reason: String,
    ):
        var stats = HnswSearchStats()
        stats.requested_ef = requested_ef
        stats.effective_ef = effective_ef
        stats.base_visited = visited
        stats.distance_evaluations = visited
        stats.retained_candidates = retained
        stats.reranked_candidates = retained
        stats.backend_name = String("portable-simd-", portable_simd_width())
        if metric == _DOT_METRIC:
            stats.metric_name = "dot"
        elif metric == _L2_METRIC:
            stats.metric_name = "l2"
        else:
            stats.metric_name = "cosine"
        stats.scalar_name = "f32"
        stats.storage_name = "exact"
        stats.fallback_reason = reason.copy()
        self._last_search_stats = stats^

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
        var ordinals = candidate_ordinals(self._memtable, candidates)
        var query_norm = _prepare_f32_query(metric, query)
        for ordinal in ordinals:
            ref entry = self._memtable.entry_ref_at(ordinal)
            if not entry.has_dense():
                continue
            var score = _prepared_f32_score(
                metric, query, entry.values(), query_norm
            )
            topk.offer(entry.id, score)

        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def _validate_hybrid(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int,
    ) raises:
        self._validate_vector(dense_query)
        validate_sparse(sparse_query)
        if k <= 0 or fetch_k < k:
            raise Error("hybrid fetch_k must be at least positive k")
        if rank_constant <= 0:
            raise Error("RRF rank constant must be positive")

    def _validate_query(self, query: List[Float32], k: Int) raises:
        self._validate_vector(query)
        if k <= 0:
            raise Error("k must be positive")

    def _validate_vector(self, values: List[Float32]) raises:
        if len(values) != self._config.dimension:
            raise Error("vector dimension does not match collection")
        for value in values:
            if not isfinite(value):
                raise Error("vectors must contain only finite values")

    def _ensure_open(self) raises:
        if self._closed:
            raise Error("collection is closed")
        if self._batch_failed:
            raise Error(
                "collection requires reopen after uncertain batch publication"
            )
        if self.path != self._path:
            raise Error("public collection path copy diverged from identity")
        if self.dimension != self._config.dimension:
            raise Error(
                "public collection dimension copy diverged from identity"
            )
        if self._point_store and (
            self._point_store.value()._io_failed
            or self._point_store.value()._table._write_failed
        ):
            raise Error(
                "collection requires reopen after uncertain point publication"
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
                raise Error(
                    "HNSW upsert source is not authoritative and current"
                )
            ref authoritative = self._memtable.entry_ref_at(ordinal)
            self._hnsw.upsert(id, authoritative.values())
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

    def _extend_hnsw_id_lookup(mut self, previous_slots: Int):
        """Extend an already-built shared lookup for newly allocated slots."""
        var current_slots = self._metadata.slot_count()
        if current_slots == previous_slots:
            return
        if (
            current_slots < previous_slots
            or not Bool(self._hnsw_id_lookup)
            or self._hnsw_id_lookup_dirty
        ):
            self._hnsw_id_lookup_dirty = True
            return
        try:
            var lookup = self._hnsw_id_lookup.value().copy()
            for ordinal in range(previous_slots, current_slots):
                lookup.append(self._metadata.id_at(ordinal), ordinal)
        except:
            self._hnsw_id_lookup_dirty = True
            self._mark_hnsw_unavailable("eligibility_failed")

    def _update_hnsw_after_delete(mut self, id: Int, was_live: Bool):
        if not self._hnsw_available:
            return
        var deleted: Bool
        try:
            deleted = self._hnsw.delete(id)
        except:
            self._mark_hnsw_unavailable("mutation_failed")
            return
        if was_live and not deleted:
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

    def _prepare_hnsw_checkpoint(mut self) raises:
        """Run due graph maintenance before taking the checkpoint writer lock.

        A concurrent build already tracks accepted writes; the checkpoint can
        proceed using the current graph while that operation finishes. A failed
        candidate never disables a still-valid graph or rejects durable writes.
        """
        with BlockingScopedLock(self._writer_lock[]):
            self._ensure_open()
            self._ensure_owned_hnsw_checkpoint()
            if self._hnsw_rebuild or not self._hnsw_requires_maintenance():
                return
        try:
            self._rebuild_hnsw(only_if_due=True)
        except:
            # Graphs are derived; authoritative checkpointing proceeds.
            pass

    def _ensure_owned_hnsw_checkpoint(mut self):
        if not self._hnsw_available or self._hnsw.checkpoint_ready():
            return
        try:
            if not self._hnsw.has_base() or self._hnsw.base_slot_count() == 0:
                self._hnsw.promote_delta_base()
                self._hnsw_base_sequence = self._last_sequence
                self._hnsw_mutations_since_rebuild = 0
        except:
            self._mark_hnsw_unavailable("rebuild_failed")

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
        var candidates: List[SearchResult],
        expected_count: Int,
        allowed: Optional[Bitmap],
    ) raises -> List[SearchResult]:
        var segmented_stats = self._hnsw.last_search_stats()
        self._last_hnsw_rerank_candidates = segmented_stats.reranked_candidates
        self._last_hnsw_rerank_ordinal_lookups = (
            self._hnsw.last_rerank_ordinal_lookups()
        )
        self._last_hnsw_rerank_linear_id_scans = (
            self._hnsw.last_rerank_linear_id_scans()
        )
        self._last_hnsw_rerank_payload_clones = 0
        try:
            if expected_count < 0 or len(candidates) != expected_count:
                raise Error(
                    "HNSW candidate count does not satisfy query contract"
                )
            return candidates^
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

    def _invalidate_cache_hits(mut self):
        self._read_generations[].invalidate()
        self._hnsw_cache_was_hit = False
        self._metadata_cache_was_hit = False

    def _publish_index_caches_best_effort(mut self):
        if (
            self._hnsw_available
            and self._hnsw.has_base()
            and self._hnsw.has_delta()
        ):
            try:
                var manifest = load_manifest(self._path, self._config.dimension)
                if (
                    manifest.hnsw_name
                    and hnsw_base_sequence(manifest) == self._hnsw_base_sequence
                ):
                    var base_checksum = manifest.hnsw_checksum.value()
                    var already_published = (
                        self._overlay_cache_sequence
                        and self._overlay_cache_sequence.value()
                        == self._last_sequence
                        and self._overlay_cache_base_sequence
                        == self._hnsw_base_sequence
                        and self._overlay_cache_base_checksum == base_checksum
                    )
                    if (
                        not already_published
                        and publish_hnsw_overlay_cache_best_effort(
                            self._path,
                            self._hnsw._delta,
                            manifest.generation,
                            self._last_sequence,
                            base_checksum,
                            self._hnsw_base_sequence,
                        )
                    ):
                        # Compaction alone cannot invalidate this verified
                        # graph key; failed publication must remain retryable.
                        self._overlay_cache_sequence = Optional(
                            self._last_sequence
                        )
                        self._overlay_cache_base_sequence = (
                            self._hnsw_base_sequence
                        )
                        self._overlay_cache_base_checksum = base_checksum
            except:
                pass
        if self._point_store:
            return
        try:
            var generation = self._read_generations[].generation
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
            if self._hnsw_available and self._hnsw.checkpoint_ready():
                var hnsw_payload = (
                    self._hnsw.checkpoint_base().encode_cache_payload()
                )
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
    if existing.rebuild_inactive_percent != requested.rebuild_inactive_percent:
        _raise_config_mismatch("rebuild_inactive_percent", existing, requested)
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


def _build_metadata(memtable: MemTable) raises -> MetadataIndex:
    var index = MetadataIndex()
    index.begin_bulk()
    for ordinal in range(memtable.slot_count()):
        ref entry = memtable.entry_ref_at(ordinal)
        if entry.tombstone:
            index.delete(entry.id)
        else:
            var fields = clone_fields(entry.fields())
            index.upsert(entry.id, fields^)
    index.finish_bulk()
    if index.slot_count() != memtable.slot_count():
        raise Error("metadata index and memtable slot alignment failed")
    return index^


def _build_hnsw_id_lookup(
    metadata: MetadataIndex,
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
    var index: SegmentedHnsw
    var sidecar_hit: Bool
    var legacy_cache_hit: Bool
    var replayed_mutations: Int
    var available: Bool
    var failure_reason: String
    var base_sequence: Optional[UInt64]

    def __init__(
        out self,
        var index: SegmentedHnsw,
        sidecar_hit: Bool,
        legacy_cache_hit: Bool,
        replayed_mutations: Int,
        available: Bool,
        failure_reason: String,
        base_sequence: Optional[UInt64] = None,
    ):
        self.index = index^
        self.sidecar_hit = sidecar_hit
        self.legacy_cache_hit = legacy_cache_hit
        self.replayed_mutations = replayed_mutations
        self.base_sequence = base_sequence
        self.available = available
        self.failure_reason = String(copy=failure_reason)

    def take_index(mut self) raises -> SegmentedHnsw:
        var config = self.index.config.copy()
        var replacement = SegmentedHnsw(config)
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
    memtable: MemTable,
    *,
    point_projection: Bool = False,
) raises -> _HnswRecoveryLoad:
    """Recover the committed graph, then apply authoritative newer WAL."""
    var has_manifest = path_exists(path + "/manifest.bin")
    if has_manifest:
        var manifest = load_manifest(path, config.dimension)
        if Bool(manifest.hnsw_name):
            var metadata_matches = (
                manifest.hnsw_config_fingerprint.value() == config.fingerprint()
                and (
                    point_projection
                    or manifest.format_version == 5
                    or manifest.hnsw_point_count.value()
                    == UInt64(len(checkpoint_live_ids))
                )
            )
            var sidecar_path = path + "/" + manifest.hnsw_name.value()
            if metadata_matches and path_exists(sidecar_path):
                var mapped = try_open_compatible_hnsw_snapshot_view(
                    sidecar_path,
                    config,
                    hnsw_base_sequence(manifest),
                    manifest.hnsw_checksum.value(),
                    manifest.hnsw_point_count.value(),
                )
                var segmented = SegmentedHnsw(config)
                var compatible = False
                if mapped.hit():
                    segmented = SegmentedHnsw.from_mapped(mapped.take_view())
                    compatible = True
                elif mapped.mapping_failed():
                    # Only acquisition failure reaches the bounded owned
                    # fallback. Matching mapped corruption raises above.
                    var owned = try_read_compatible_hnsw_snapshot_owned(
                        sidecar_path,
                        config,
                        hnsw_base_sequence(manifest),
                        manifest.hnsw_checksum.value(),
                        manifest.hnsw_point_count.value(),
                    )
                    if Bool(owned):
                        segmented = SegmentedHnsw.from_owned(owned.take())
                        compatible = True
                if compatible and (
                    point_projection or manifest.format_version == 5
                ):
                    try:
                        var cached_delta = load_hnsw_overlay_cache(
                            path,
                            config,
                            generation,
                            last_sequence,
                            manifest.hnsw_checksum.value(),
                            hnsw_base_sequence(manifest),
                        )
                        var replayed = restore_hnsw_overlay(
                            segmented,
                            memtable,
                            hnsw_base_sequence(manifest),
                            cached_delta^,
                        )
                        return _HnswRecoveryLoad(
                            segmented^,
                            True,
                            False,
                            replayed,
                            True,
                            "",
                            Optional(hnsw_base_sequence(manifest)),
                        )
                    except:
                        return _rebuild_hnsw_for_recovery(memtable, config)
                if compatible and _hnsw_matches_ids(
                    segmented, checkpoint_live_ids
                ):
                    try:
                        var replayed = _replay_hnsw_wal(
                            segmented,
                            checkpoint_sequence,
                            path + "/wal.bin",
                            config,
                        )
                        if _hnsw_matches_memtable(segmented, memtable):
                            segmented.validate_overlay()
                            return _HnswRecoveryLoad(
                                segmented^,
                                True,
                                False,
                                replayed,
                                True,
                                "",
                                Optional(hnsw_base_sequence(manifest)),
                            )
                    except:
                        pass
            # Missing files and stale descriptor/header metadata are derived
            # acceleration misses. They never invalidate authoritative data.
            return _rebuild_hnsw_for_recovery(memtable, config)

    if point_projection:
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
        var segmented = SegmentedHnsw.from_owned(cached^)
        return _HnswRecoveryLoad(segmented^, False, True, 0, True, "")
    return _rebuild_hnsw_for_recovery(memtable, config)


def _rebuild_hnsw_for_recovery(
    memtable: MemTable, config: CollectionConfig
) raises -> _HnswRecoveryLoad:
    try:
        var rebuilt = _build_hnsw(memtable, config)
        var segmented = SegmentedHnsw.from_owned(rebuilt^)
        return _HnswRecoveryLoad(segmented^, False, False, 0, True, "")
    except:
        # Authoritative records remain queryable through exact plans when the
        # configured graph backend cannot represent this scalar/layout.
        var unavailable = SegmentedHnsw(config)
        return _HnswRecoveryLoad(
            unavailable^, False, False, 0, False, "rebuild_failed"
        )


def _hnsw_matches_ids(index: SegmentedHnsw, ids: Dict[Int, Bool]) -> Bool:
    if index.current_point_count() != len(ids):
        return False
    for id in ids:
        if not index.contains_current(id):
            return False
    return True


def _hnsw_matches_memtable(
    index: SegmentedHnsw, memtable: MemTable
) raises -> Bool:
    var ids = Dict[Int, Bool]()
    for ordinal in range(memtable.slot_count()):
        if (
            memtable.is_live_at(ordinal)
            and memtable.entry_ref_at(ordinal).has_dense()
        ):
            ids[memtable.id_at(ordinal)] = True
    return _hnsw_matches_ids(index, ids)


def _replay_hnsw_wal(
    mut index: SegmentedHnsw,
    checkpoint_sequence: UInt64,
    wal_path: String,
    config: CollectionConfig,
) raises -> Int:
    # The collection lock still excludes writers. Re-read bounded envelopes
    # instead of retaining historical vectors/payloads through all recovery.
    var reader = WalReader(wal_path, config.dimension)
    var replayed = 0
    while True:
        var records = reader.read_next()
        if len(records) == 0:
            break
        for record_index in range(len(records)):
            ref record = records[record_index]
            if record.sequence <= checkpoint_sequence:
                continue
            if record.is_delete:
                _ = index.delete(record.id)
            else:
                index.upsert(record.id, record.values)
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
                or decoded.live_count() != memtable.live_count()
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
