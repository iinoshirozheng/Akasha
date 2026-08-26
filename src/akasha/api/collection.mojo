from akasha.compute.simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
from akasha.compute.topk import BoundedTopK
from akasha.api.batch import BatchMutation, BatchWriteResult
from akasha.document.record import (
    clone_fields,
    DocumentField,
    DocumentRecord,
    validate_fields,
)
from akasha.index.bitmap import Bitmap
from akasha.index.flat import SearchResult
from akasha.index.hnsw import HnswIndex
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
from akasha.storage.filesystem import (
    atomic_replace,
    ensure_directory,
    path_exists,
    remove_file_if_exists,
    sync_directory,
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
    write_segment_v3,
)
from akasha.storage.sparse_store import (
    append_sparse_wal,
    latest_sparse_records,
    read_sparse_segment,
    read_sparse_snapshot,
    recover_sparse_wal,
    rotate_sparse_wal,
    SPARSE_SEGMENT_KIND_BASE,
    SPARSE_SEGMENT_KIND_DELTA,
    SparseWalRecord,
    write_sparse_segment,
)
from akasha.storage.wal import (
    append_wal,
    append_wal_batch,
    recover_wal,
    rotate_wal,
    WalRecord,
)
from std.math import isfinite
from std.memory import ArcPointer


comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct _RetiredGeneration(Movable):
    var maximum_generation: UInt64
    var files: List[String]

    def __init__(out self, maximum_generation: UInt64, var files: List[String]):
        self.maximum_generation = maximum_generation
        self.files = files^

    def clone(self) -> _RetiredGeneration:
        var files = List[String](capacity=len(self.files))
        for index in range(len(self.files)):
            files.append(String(copy=self.files[index]))
        return _RetiredGeneration(self.maximum_generation, files^)


struct PersistentCollection:
    """A durable, single-writer exact vector collection."""

    var path: String
    var dimension: Int
    var _wal_path: String
    var _memtable: MemTable
    var _last_sequence: UInt64
    var _lock: CollectionLock
    var _closed: Bool
    var _hnsw: HnswIndex
    var _hnsw_dirty: Bool
    var _sparse: SparseIndex
    var _sparse_wal_path: String
    var _sparse_pending: List[SparseWalRecord]
    var _metadata: MetadataIndex
    var _pins: ArcPointer[GenerationPinRegistry]
    var _retired: List[_RetiredGeneration]

    def __init__(
        out self,
        path: String,
        dimension: Int,
        var memtable: MemTable,
        last_sequence: UInt64,
        var lock: CollectionLock,
        var hnsw: HnswIndex,
        var sparse: SparseIndex,
        var sparse_pending: List[SparseWalRecord],
        var metadata: MetadataIndex,
    ):
        self.path = String(copy=path)
        self.dimension = dimension
        self._wal_path = path + "/wal.bin"
        self._memtable = memtable^
        self._last_sequence = last_sequence
        self._lock = lock^
        self._closed = False
        self._hnsw = hnsw^
        self._hnsw_dirty = False
        self._sparse = sparse^
        self._sparse_wal_path = path + "/sparse.wal"
        self._sparse_pending = sparse_pending^
        self._metadata = metadata^
        self._pins = ArcPointer(GenerationPinRegistry())
        self._retired = List[_RetiredGeneration]()

    @staticmethod
    def open(path: String, dimension: Int) raises -> PersistentCollection:
        """Create or recover a persistent collection at ``path``."""
        if dimension <= 0:
            raise Error("collection dimension must be positive")
        ensure_directory(path)
        var lock = CollectionLock.acquire(path + "/collection.lock")

        var memtable = MemTable(dimension)
        var snapshot_sequence = UInt64(0)
        var manifest_path = path + "/manifest.bin"
        if path_exists(manifest_path):
            var manifest = load_manifest(path, dimension)
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

        var records = recover_wal(path + "/wal.bin", dimension)
        var last_sequence = snapshot_sequence
        for index in range(len(records)):
            if records[index].sequence <= snapshot_sequence:
                continue
            if records[index].is_delete:
                memtable.apply_delete(
                    records[index].id, records[index].sequence
                )
            else:
                var values = _clone_vector(records[index].values)
                var fields = clone_fields(records[index].fields)
                memtable.apply_document_upsert(
                    records[index].id,
                    records[index].sequence,
                    values^,
                    fields^,
                )
            last_sequence = records[index].sequence

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
        var sparse_wal = recover_sparse_wal(path + "/sparse.wal")
        for index in range(len(sparse_wal)):
            if sparse_wal[index].sequence <= snapshot_sequence:
                continue
            if sparse_wal[index].is_delete:
                sparse.delete(sparse_wal[index].id)
            else:
                sparse.upsert(sparse_wal[index].id, sparse_wal[index].elements)
            sparse_pending.append(sparse_wal[index].clone())
            if sparse_wal[index].sequence > last_sequence:
                last_sequence = sparse_wal[index].sequence
        var recovered_sparse = sparse.records()
        for index in range(len(recovered_sparse)):
            if not Bool(memtable.get(recovered_sparse[index].id)):
                sparse.delete(recovered_sparse[index].id)

        # HNSW is a derived cache. Rebuilding it eagerly makes collection open
        # quadratic in the number of recovered points; the first approximate
        # query rebuilds it through `_ensure_hnsw()` instead.
        var hnsw = HnswIndex(dimension)
        var metadata = _build_metadata(memtable)
        var recovered_point_count = memtable.entry_count()
        var collection = PersistentCollection(
            path,
            dimension,
            memtable^,
            last_sequence,
            lock^,
            hnsw^,
            sparse^,
            sparse_pending^,
            metadata^,
        )
        collection._hnsw_dirty = recovered_point_count > 0
        return collection^

    def close(mut self) raises:
        """Release this collection's single-writer ownership."""
        if self._closed:
            return
        self._lock.close()
        self._closed = True

    def last_sequence(self) raises -> UInt64:
        self._ensure_open()
        return self._last_sequence

    def metadata_live_count(self) raises -> Int:
        self._ensure_open()
        return self._metadata.live_count()

    def metadata_match_count(self, expression: FilterExpression) raises -> Int:
        self._ensure_open()
        return evaluate_expression(self._metadata, expression).count()

    def snapshot(self) raises -> ReadSnapshot:
        """Capture an immutable owned view of all currently visible records."""
        self._ensure_open()
        var generation = UInt64(0)
        if path_exists(self.path + "/manifest.bin"):
            generation = load_manifest(self.path, self.dimension).generation
        return ReadSnapshot.capture(
            self.dimension,
            generation,
            self._last_sequence,
            self._memtable,
            self._pins,
        )

    def upsert(mut self, id: Int, var values: List[Float32]) raises:
        self._ensure_open()
        self._validate_vector(values)
        var sequence = self._next_sequence()
        var wal_values = _clone_vector(values)
        var record = WalRecord.upsert(sequence, id, wal_values^)
        append_wal(self._wal_path, self.dimension, record)
        self._memtable.apply_upsert(id, sequence, values^)
        var metadata_fields = List[DocumentField]()
        self._metadata.upsert(id, metadata_fields^)
        self._last_sequence = sequence
        self._hnsw_dirty = True

    def upsert_document(
        mut self,
        id: Int,
        var values: List[Float32],
        var fields: List[DocumentField],
    ) raises:
        self._ensure_open()
        self._validate_vector(values)
        var sequence = self._next_sequence()
        var wal_values = _clone_vector(values)
        var wal_fields = clone_fields(fields)
        var metadata_fields = clone_fields(fields)
        var record = WalRecord.document_upsert(
            sequence, id, wal_values^, wal_fields^
        )
        append_wal(self._wal_path, self.dimension, record)
        self._memtable.apply_document_upsert(id, sequence, values^, fields^)
        self._metadata.upsert(id, metadata_fields^)
        self._last_sequence = sequence
        self._hnsw_dirty = True

    def apply_batch(
        mut self, mutations: List[BatchMutation]
    ) raises -> BatchWriteResult:
        """Validate and durably apply one all-or-nothing dense mutation batch.
        """
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

        append_wal_batch(self._wal_path, self.dimension, records)
        self._memtable = staged_memtable^
        self._metadata = staged_metadata^
        for index in range(len(mutations)):
            if mutations[index].is_delete:
                self._sparse.delete(mutations[index].id)
        var last_sequence = first_sequence + UInt64(len(mutations) - 1)
        self._last_sequence = last_sequence
        self._hnsw_dirty = True
        return BatchWriteResult(first_sequence, last_sequence, len(mutations))

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        self._ensure_open()
        return self._memtable.get(id)

    def upsert_sparse(mut self, id: Int, elements: List[SparseElement]) raises:
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

    def delete(mut self, id: Int) raises:
        self._ensure_open()
        var sequence = self._next_sequence()
        var record = WalRecord.delete(sequence, id)
        append_wal(self._wal_path, self.dimension, record)
        self._memtable.apply_delete(id, sequence)
        self._metadata.delete(id)
        self._sparse.delete(id)
        self._last_sequence = sequence
        self._hnsw_dirty = True

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

    def search_dot_approx(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        return self._search_approx(query, k, ef_search, _DOT_METRIC)

    def search_l2_approx(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        return self._search_approx(query, k, ef_search, _L2_METRIC)

    def search_cosine_approx(
        mut self, query: List[Float32], k: Int, ef_search: Int
    ) raises -> List[SearchResult]:
        return self._search_approx(query, k, ef_search, _COSINE_METRIC)

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
        return self._search_approx_where(
            query, k, ef_search, _DOT_METRIC, expression
        )

    def search_l2_approx_where(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_approx_where(
            query, k, ef_search, _L2_METRIC, expression
        )

    def search_cosine_approx_where(
        mut self,
        query: List[Float32],
        k: Int,
        ef_search: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        return self._search_approx_where(
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
        self._ensure_open()
        self._reclaim_retired()
        var previous_sequence = UInt64(0)
        var generation = UInt64(1)
        var has_previous_manifest = False
        var descriptors = List[SegmentDescriptor]()
        if path_exists(self.path + "/manifest.bin"):
            var previous_manifest = load_manifest(self.path, self.dimension)
            previous_sequence = previous_manifest.last_sequence
            has_previous_manifest = True
            if self._last_sequence < previous_sequence:
                raise Error("collection sequence precedes checkpoint")
            if self._last_sequence == previous_sequence:
                rotate_wal(self.path)
                rotate_sparse_wal(self.path)
                self._sparse_pending = List[SparseWalRecord]()
                return
            if previous_manifest.format_version == 2:
                if previous_manifest.generation == UInt64.MAX:
                    raise Error("manifest generation exhausted")
                generation = previous_manifest.generation + 1
            for index in range(len(previous_manifest.segments)):
                descriptors.append(previous_manifest.segments[index].clone())

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
        var sparse_temporary = self.path + "/" + sparse_name + ".tmp"
        var sparse_checksum = write_sparse_segment(
            sparse_temporary,
            sparse_kind,
            0 if not has_previous_manifest else previous_sequence + 1,
            self._last_sequence,
            sparse_mutations,
        )
        atomic_replace(sparse_temporary, self.path + "/" + sparse_name)
        sync_directory(self.path)

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
        var temporary_path = self.path + "/" + segment_name + ".tmp"
        var final_path = self.path + "/" + segment_name
        var checksum = write_segment_v3(
            temporary_path,
            self.dimension,
            kind,
            min_sequence,
            self._last_sequence,
            entries,
        )
        atomic_replace(temporary_path, final_path)
        sync_directory(self.path)
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
        var manifest = Manifest.with_segments(
            self.dimension,
            generation,
            self._last_sequence,
            descriptors^,
        )
        publish_manifest(self.path, manifest)
        rotate_wal(self.path)
        rotate_sparse_wal(self.path)
        self._sparse_pending = List[SparseWalRecord]()
        var policy = CompactionPolicy(4)
        if policy.should_compact(manifest):
            self._compact_committed(manifest^)

    def compact(mut self) raises:
        """Replace the committed segment set with one complete live base."""
        self._ensure_open()
        self.flush()
        if not path_exists(self.path + "/manifest.bin"):
            return
        var previous = load_manifest(self.path, self.dimension)
        if len(previous.segments) <= 1:
            return
        self._compact_committed(previous^)

    def _compact_committed(mut self, var previous: Manifest) raises:
        if previous.generation == UInt64.MAX:
            raise Error("manifest generation exhausted")

        var sparse_name = "sparse-base-" + String(self._last_sequence) + ".bin"
        var sparse_temporary = self.path + "/" + sparse_name + ".tmp"
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
        atomic_replace(sparse_temporary, self.path + "/" + sparse_name)
        sync_directory(self.path)

        var segment_name = (
            "segment-base-" + String(self._last_sequence) + ".bin"
        )
        var segment_temporary = self.path + "/" + segment_name + ".tmp"
        var live_entries = self._memtable.live_entries()
        var checksum = write_segment_v3(
            segment_temporary,
            self.dimension,
            SEGMENT_KIND_BASE,
            0,
            self._last_sequence,
            live_entries,
        )
        atomic_replace(segment_temporary, self.path + "/" + segment_name)
        sync_directory(self.path)

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
        var compacted = Manifest.with_segments(
            self.dimension,
            previous.generation + 1,
            self._last_sequence,
            descriptors^,
        )
        publish_manifest(self.path, compacted)

        self._retire_or_reclaim(previous, segment_name, sparse_name)

    def maintenance(mut self) raises -> Bool:
        """Run synchronous compaction when the default L0 threshold is met."""
        self._ensure_open()
        self._reclaim_retired()
        self.flush()
        if not path_exists(self.path + "/manifest.bin"):
            return False
        var manifest = load_manifest(self.path, self.dimension)
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
                removed.append(self.path + "/" + previous.segments[index].name)
            if (
                previous.segments[index].sparse_name.byte_length() > 0
                and previous.segments[index].sparse_name != retained_sparse
            ):
                removed.append(
                    self.path + "/" + previous.segments[index].sparse_name
                )

        if self._pins[].has_pin_at_or_before(previous.generation):
            self._retired.append(
                _RetiredGeneration(previous.generation, removed^)
            )
            return
        for index in range(len(removed)):
            remove_file_if_exists(removed[index])
        sync_directory(self.path)

    def _reclaim_retired(mut self) raises:
        if len(self._retired) == 0:
            return
        var retained = List[_RetiredGeneration]()
        var removed_any = False
        for index in range(len(self._retired)):
            if self._pins[].has_pin_at_or_before(
                self._retired[index].maximum_generation
            ):
                retained.append(self._retired[index].clone())
                continue
            for file_index in range(len(self._retired[index].files)):
                remove_file_if_exists(self._retired[index].files[file_index])
            removed_any = True
        self._retired = retained^
        if removed_any:
            sync_directory(self.path)

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

    def _search_approx(
        mut self, query: List[Float32], k: Int, ef_search: Int, metric: Int
    ) raises -> List[SearchResult]:
        self._ensure_open()
        self._validate_vector(query)
        if k <= 0:
            raise Error("k must be positive")
        if ef_search <= 0:
            raise Error("ef_search must be positive")
        self._ensure_hnsw()
        var count = self._hnsw.point_count()
        if not QueryPlanner.use_hnsw(count, k, count, False):
            var conditions = List[FilterCondition]()
            return self._search_filtered(query, k, metric, conditions)
        if metric == _DOT_METRIC:
            return self._hnsw.search_dot(query, k, ef_search)
        if metric == _L2_METRIC:
            return self._hnsw.search_l2(query, k, ef_search)
        return self._hnsw.search_cosine(query, k, ef_search)

    def _search_approx_where(
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
        self._ensure_hnsw()
        var matched = evaluate_expression(self._metadata, expression)
        var matched_count = matched.count()
        var total_count = self._metadata.live_count()
        if not QueryPlanner.use_hnsw(total_count, k, matched_count, True):
            return self._search_where(query, k, metric, expression)

        var overfetch = ef_search
        if overfetch < k * 4:
            overfetch = k * 4
        if overfetch > total_count:
            overfetch = total_count
        var candidates: List[SearchResult]
        if metric == _DOT_METRIC:
            candidates = self._hnsw.search_dot(query, overfetch, ef_search)
        elif metric == _L2_METRIC:
            candidates = self._hnsw.search_l2(query, overfetch, ef_search)
        else:
            candidates = self._hnsw.search_cosine(query, overfetch, ef_search)

        var target = k
        if target > matched_count:
            target = matched_count
        var accepted = List[SearchResult](capacity=target)
        for candidate in candidates:
            if self._metadata.contains_id(matched, candidate.id):
                accepted.append(candidate)
            if len(accepted) == target:
                return accepted^
        return self._search_where(query, k, metric, expression)

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
        if len(values) != self.dimension:
            raise Error("vector dimension does not match collection")
        for value in values:
            if not isfinite(value):
                raise Error("vectors must contain only finite values")

    def _ensure_open(self) raises:
        if self._closed:
            raise Error("collection is closed")

    def _ensure_hnsw(mut self) raises:
        if not self._hnsw_dirty:
            return
        var rebuilt = _build_hnsw(self._memtable, self.dimension)
        self._hnsw = rebuilt^
        self._hnsw_dirty = False

    def _next_sequence(self) raises -> UInt64:
        if self._last_sequence == UInt64.MAX:
            raise Error("collection sequence exhausted")
        return self._last_sequence + 1


def _clone_vector(values: List[Float32]) -> List[Float32]:
    var result = List[Float32](capacity=len(values))
    for value in values:
        result.append(value)
    return result^


def _build_hnsw(memtable: MemTable, dimension: Int) raises -> HnswIndex:
    var index = HnswIndex(dimension)
    var entries = memtable.live_entries()
    for entry_index in range(len(entries)):
        index.add(entries[entry_index].id, entries[entry_index].values)
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
