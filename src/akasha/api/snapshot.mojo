from akasha.compute.simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
from akasha.common.config import CollectionConfig
from akasha.compute.topk import BoundedTopK
from akasha.compute.gpu.flat_scan import (
    DeviceBatchResult,
    execute_snapshot_device_batch,
)
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.document.record import (
    clone_fields,
    DocumentRecord,
    FieldProjection,
    project_document,
)
from akasha.index.flat import SearchResult
from akasha.index.quantization import PqIndex, Sq8Index
from akasha.index.sparse import SparseElement, SparseRecord, validate_sparse
from akasha.query.control import QueryControl
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.fusion import reciprocal_rank_fusion
from akasha.query.parallel_scan import execute_parallel_scan
from akasha.query.batch_executor import (
    BATCH_COSINE_METRIC,
    BATCH_DOT_METRIC,
    BATCH_L2_METRIC,
    execute_exact_candidate_batch,
    execute_exact_ordinal_batch,
)
from akasha.storage.read_generation import (
    contains_sorted,
    ReadGeneration,
    ReadRun,
)
from std.math import isfinite
from std.memory import ArcPointer
from std.utils import BlockingScopedLock, BlockingSpinLock


comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct _RootSlot(Movable):
    """A handle's root owner and the lock that guards it."""

    var lock: BlockingSpinLock
    var root: Optional[ArcPointer[ReadGeneration]]

    def __init__(out self, var root: ArcPointer[ReadGeneration]):
        self.lock = BlockingSpinLock()
        self.root = Optional(root^)


struct ReadSnapshot(Movable):
    """An immutable, owned collection view at one accepted sequence."""

    var _config: CollectionConfig
    var _dimension: Int
    var _generation: UInt64
    var _sequence: UInt64
    # Shared behind a pointer so close can race queries on one handle.
    var _slot: ArcPointer[_RootSlot]

    def __init__(out self, var root: ArcPointer[ReadGeneration]):
        self._config = root[].config.copy()
        self._dimension = root[].config.dimension
        self._generation = root[].generation
        self._sequence = root[].sequence
        self._slot = ArcPointer(_RootSlot(root^))

    def close(mut self):
        """Stop new operations and drop this handle's root owner; idempotent.

        Acquired operations own the root and finish unaffected. The last owner
        releases the root's rows, device state and generation pin, outside
        the handle lock.
        """
        var released = Optional[ArcPointer[ReadGeneration]]()
        with BlockingScopedLock(self._slot[].lock):
            if self._slot[].root:
                released = Optional(self._slot[].root.take())
        _ = released^

    def _acquire(self) raises -> ArcPointer[ReadGeneration]:
        """Return an operation owner of the root; queries read only through it.
        """
        var root = Optional[ArcPointer[ReadGeneration]]()
        with BlockingScopedLock(self._slot[].lock):
            if self._slot[].root:
                root = Optional(self._slot[].root.value().copy())
        if not root:
            raise Error("snapshot is closed")
        return root.take()

    def generation(self) -> UInt64:
        return self._generation

    def last_sequence(self) -> UInt64:
        return self._sequence

    def collection_config(self) -> CollectionConfig:
        return self._config.copy()

    def config_fingerprint(self) -> UInt64:
        return self._config.fingerprint()

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        var root = self._acquire()
        ref view = root[]
        var location = view.find(id)
        if location[0] < 0:
            return Optional[DocumentRecord]()
        return Optional(self._record_at(view, location))

    def get_projected(
        self, id: Int, projection: FieldProjection
    ) raises -> Optional[DocumentRecord]:
        var document = self.get(id)
        if not Bool(document):
            return Optional[DocumentRecord]()
        return Optional(project_document(document.value(), projection))

    def documents(self) raises -> List[DocumentRecord]:
        """Return owned live records for logical export."""
        var root = self._acquire()
        ref view = root[]
        var locations = view.id_ordered_locations()
        var records = List[DocumentRecord](capacity=len(locations))
        for location in locations:
            records.append(self._record_at(view, location))
        return records^

    def sparse_records(self) raises -> List[SparseRecord]:
        """Return an owned sparse snapshot for logical export."""
        var root = self._acquire()
        ref view = root[]
        var records = List[SparseRecord]()
        for location in view.id_ordered_locations():
            ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
            if entry.has_sparse():
                records.append(SparseRecord(entry.id, entry.sparse().copy()))
        return records^

    def _record_at(
        self, view: ReadGeneration, location: Tuple[Int, Int]
    ) raises -> DocumentRecord:
        """Materialize an owned record; later mutation cannot reach the run."""
        ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
        return DocumentRecord(
            entry.id,
            entry.sequence,
            entry.values().copy(),
            clone_fields(entry.fields()),
        )

    def search_dot(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        var conditions = List[FilterCondition]()
        return self._search_filtered(view, query, k, _DOT_METRIC, conditions)

    def search_l2(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        var conditions = List[FilterCondition]()
        return self._search_filtered(view, query, k, _L2_METRIC, conditions)

    def search_cosine(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        var conditions = List[FilterCondition]()
        return self._search_filtered(view, query, k, _COSINE_METRIC, conditions)

    def search_dot_controlled(
        self, query: List[Float32], k: Int, control: QueryControl
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_controlled(view, query, k, _DOT_METRIC, control)

    def search_l2_controlled(
        self, query: List[Float32], k: Int, control: QueryControl
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_controlled(view, query, k, _L2_METRIC, control)

    def search_cosine_controlled(
        self, query: List[Float32], k: Int, control: QueryControl
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_controlled(view, query, k, _COSINE_METRIC, control)

    def search_dot_parallel(
        self, query: List[Float32], k: Int, *, num_workers: Int = 0
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_parallel(
            view, query, k, _DOT_METRIC, num_workers, self._visible_layers(view)
        )

    def search_l2_parallel(
        self, query: List[Float32], k: Int, *, num_workers: Int = 0
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_parallel(
            view, query, k, _L2_METRIC, num_workers, self._visible_layers(view)
        )

    def search_cosine_parallel(
        self, query: List[Float32], k: Int, *, num_workers: Int = 0
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_parallel(
            view,
            query,
            k,
            _COSINE_METRIC,
            num_workers,
            self._visible_layers(view),
        )

    def search_sq8_dot(
        self, query: List[Float32], k: Int, *, rerank_k: Int = 0
    ) raises -> List[SearchResult]:
        """Search an immutable SQ8 view and optionally exact-rerank candidates.
        """
        var root = self._acquire()
        ref view = root[]
        return self._search_sq8(view, query, k, rerank_k, _DOT_METRIC)

    def search_sq8_l2(
        self, query: List[Float32], k: Int, *, rerank_k: Int = 0
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_sq8(view, query, k, rerank_k, _L2_METRIC)

    def search_sq8_cosine(
        self, query: List[Float32], k: Int, *, rerank_k: Int = 0
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_sq8(view, query, k, rerank_k, _COSINE_METRIC)

    def search_pq_dot(
        self,
        query: List[Float32],
        k: Int,
        *,
        subquantizers: Int,
        centroids: Int,
        rerank_k: Int = 0,
        iterations: Int = 8,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_pq(
            view,
            query,
            k,
            subquantizers,
            centroids,
            rerank_k,
            iterations,
            _DOT_METRIC,
        )

    def search_pq_l2(
        self,
        query: List[Float32],
        k: Int,
        *,
        subquantizers: Int,
        centroids: Int,
        rerank_k: Int = 0,
        iterations: Int = 8,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_pq(
            view,
            query,
            k,
            subquantizers,
            centroids,
            rerank_k,
            iterations,
            _L2_METRIC,
        )

    def search_pq_cosine(
        self,
        query: List[Float32],
        k: Int,
        *,
        subquantizers: Int,
        centroids: Int,
        rerank_k: Int = 0,
        iterations: Int = 8,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_pq(
            view,
            query,
            k,
            subquantizers,
            centroids,
            rerank_k,
            iterations,
            _COSINE_METRIC,
        )

    def search_dot_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var root = self._acquire()
        ref view = root[]
        return self._search_batch(
            view, queries, k, BATCH_DOT_METRIC, num_workers
        )

    def search_l2_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var root = self._acquire()
        ref view = root[]
        return self._search_batch(
            view, queries, k, BATCH_L2_METRIC, num_workers
        )

    def search_cosine_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var root = self._acquire()
        ref view = root[]
        return self._search_batch(
            view, queries, k, BATCH_COSINE_METRIC, num_workers
        )

    def search_device_dot_batch[
        use_accelerator: Bool
    ](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var root = self._acquire()
        ref view = root[]
        return self._search_device_batch[use_accelerator](
            view, queries, k, BATCH_DOT_METRIC, options
        )

    def search_device_l2_batch[
        use_accelerator: Bool
    ](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var root = self._acquire()
        ref view = root[]
        return self._search_device_batch[use_accelerator](
            view, queries, k, BATCH_L2_METRIC, options
        )

    def search_device_cosine_batch[
        use_accelerator: Bool
    ](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var root = self._acquire()
        ref view = root[]
        return self._search_device_batch[use_accelerator](
            view, queries, k, BATCH_COSINE_METRIC, options
        )

    def search_dot_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var root = self._acquire()
        ref view = root[]
        return self._search_where_batch(
            view, queries, expressions, k, BATCH_DOT_METRIC, num_workers
        )

    def search_l2_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var root = self._acquire()
        ref view = root[]
        return self._search_where_batch(
            view, queries, expressions, k, BATCH_L2_METRIC, num_workers
        )

    def search_cosine_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        var root = self._acquire()
        ref view = root[]
        return self._search_where_batch(
            view, queries, expressions, k, BATCH_COSINE_METRIC, num_workers
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
        var root = self._acquire()
        ref view = root[]
        return self._search_device_where_batch[use_accelerator](
            view, queries, expressions, k, BATCH_DOT_METRIC, options
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
        var root = self._acquire()
        ref view = root[]
        return self._search_device_where_batch[use_accelerator](
            view, queries, expressions, k, BATCH_L2_METRIC, options
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
        var root = self._acquire()
        ref view = root[]
        return self._search_device_where_batch[use_accelerator](
            view, queries, expressions, k, BATCH_COSINE_METRIC, options
        )

    def search_dot_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_filtered(view, query, k, _DOT_METRIC, conditions)

    def search_l2_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_filtered(view, query, k, _L2_METRIC, conditions)

    def search_cosine_filtered(
        self,
        query: List[Float32],
        k: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_filtered(view, query, k, _COSINE_METRIC, conditions)

    def search_dot_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_where(view, query, k, _DOT_METRIC, expression)

    def search_l2_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_where(view, query, k, _L2_METRIC, expression)

    def search_cosine_where(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_where(view, query, k, _COSINE_METRIC, expression)

    def search_dot_where_parallel(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
        *,
        num_workers: Int = 0,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_where_parallel(
            view, query, k, expression, _DOT_METRIC, num_workers
        )

    def search_l2_where_parallel(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
        *,
        num_workers: Int = 0,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_where_parallel(
            view, query, k, expression, _L2_METRIC, num_workers
        )

    def search_cosine_where_parallel(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
        *,
        num_workers: Int = 0,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_where_parallel(
            view, query, k, expression, _COSINE_METRIC, num_workers
        )

    def search_sparse_dot(
        self, query: List[SparseElement], k: Int
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_sparse(view, query, k, Optional[List[List[Int]]]())

    def search_sparse_dot_where(
        self,
        query: List[SparseElement],
        k: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        validate_sparse(query)
        expression.validate()
        return self._search_sparse(
            view, query, k, Optional(self._where_layers(view, expression))
        )

    def _search_sparse(
        self,
        view: ReadGeneration,
        query: List[SparseElement],
        k: Int,
        matched: Optional[List[List[Int]]],
    ) raises -> List[SearchResult]:
        """Score each run's visible rows, then merge into one Top-K.

        `matched` holds each run's ascending filter matches, when filtered.
        """
        validate_sparse(query)
        if k <= 0:
            raise Error("k must be positive")
        var hits = List[SearchResult]()
        for layer in range(view.layer_count()):
            for hit in view.sparse_hits(layer, query):
                if not matched or contains_sorted(
                    matched.value()[layer], hit.ordinal
                ):
                    hits.append(SearchResult(hit.id, hit.score))
        if len(hits) == 0:
            return hits^
        var topk = BoundedTopK(min(k, len(hits)), smaller_is_better=False)
        for hit in hits:
            topk.offer(hit.id, hit.score)
        var results = List[SearchResult]()
        for entry in topk.sorted_entries():
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def search_hybrid_dot(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int = 60,
    ) raises -> List[SearchResult]:
        var root = self._acquire()
        ref view = root[]
        return self._search_hybrid(
            view,
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
        var root = self._acquire()
        ref view = root[]
        return self._search_hybrid(
            view,
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
        var root = self._acquire()
        ref view = root[]
        return self._search_hybrid(
            view,
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
        var root = self._acquire()
        ref view = root[]
        return self._search_hybrid_where(
            view,
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
        var root = self._acquire()
        ref view = root[]
        return self._search_hybrid_where(
            view,
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
        var root = self._acquire()
        ref view = root[]
        return self._search_hybrid_where(
            view,
            dense_query,
            sparse_query,
            k,
            fetch_k,
            rank_constant,
            _COSINE_METRIC,
            expression,
        )

    def _search_filtered(
        self,
        view: ReadGeneration,
        query: List[Float32],
        k: Int,
        metric: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        for index in range(len(conditions)):
            conditions[index].validate()
        var layers = List[List[Int]](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            layers.append(view.conditioned_ordinals(layer, conditions))
        return self._scan(view, query, k, metric, layers)

    def _search_sq8(
        self,
        view: ReadGeneration,
        query: List[Float32],
        k: Int,
        rerank_k: Int,
        metric: Int,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        if rerank_k < 0 or (rerank_k > 0 and rerank_k < k):
            raise Error("SQ8 rerank candidate count must be zero or at least k")
        var ordinals = view.id_ordered_locations()
        if len(ordinals) == 0:
            return List[SearchResult]()
        var ids = List[Int](capacity=len(ordinals))
        var vectors = List[List[Float32]](capacity=len(ordinals))
        self._gather(view, ordinals, ids, vectors)
        var sq8 = Sq8Index.build(ids, vectors)
        var candidate_count = k if rerank_k == 0 else rerank_k
        candidate_count = min(candidate_count, len(ordinals))
        var candidates: List[SearchResult]
        if metric == _DOT_METRIC:
            candidates = sq8.search_dot(query, candidate_count)
        elif metric == _L2_METRIC:
            candidates = sq8.search_l2(query, candidate_count)
        else:
            candidates = sq8.search_cosine(query, candidate_count)
        if rerank_k == 0:
            return candidates^

        return self._exact_rerank(view, query, k, metric, candidates)

    def _search_pq(
        self,
        view: ReadGeneration,
        query: List[Float32],
        k: Int,
        subquantizers: Int,
        centroids: Int,
        rerank_k: Int,
        iterations: Int,
        metric: Int,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        if rerank_k < 0 or (rerank_k > 0 and rerank_k < k):
            raise Error("PQ rerank candidate count must be zero or at least k")
        var ordinals = view.id_ordered_locations()
        if len(ordinals) == 0:
            return List[SearchResult]()
        var ids = List[Int](capacity=len(ordinals))
        var vectors = List[List[Float32]](capacity=len(ordinals))
        self._gather(view, ordinals, ids, vectors)
        var pq = PqIndex.build(
            ids,
            vectors,
            subquantizers,
            centroids,
            iterations=iterations,
        )
        var candidate_count = k if rerank_k == 0 else rerank_k
        candidate_count = min(candidate_count, len(ordinals))
        var candidates: List[SearchResult]
        if metric == _DOT_METRIC:
            candidates = pq.search_dot(query, candidate_count)
        elif metric == _L2_METRIC:
            candidates = pq.search_l2(query, candidate_count)
        else:
            candidates = pq.search_cosine(query, candidate_count)
        if rerank_k == 0:
            return candidates^
        return self._exact_rerank(view, query, k, metric, candidates)

    def _exact_rerank(
        self,
        view: ReadGeneration,
        query: List[Float32],
        k: Int,
        metric: Int,
        candidates: List[SearchResult],
    ) raises -> List[SearchResult]:
        var topk = BoundedTopK(
            min(k, len(candidates)),
            smaller_is_better=metric == _L2_METRIC,
        )
        for candidate in candidates:
            var location = view.find(candidate.id)
            if location[0] < 0:
                raise Error("quantized candidate is absent from snapshot")
            ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
            topk.offer(entry.id, _score(metric, query, entry.values()))
        var retained = topk.sorted_entries()
        var output = List[SearchResult](capacity=len(retained))
        for entry in retained:
            output.append(SearchResult(entry.id, entry.score))
        return output^

    def _search_where(
        self,
        view: ReadGeneration,
        query: List[Float32],
        k: Int,
        metric: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        expression.validate()
        return self._scan(
            view, query, k, metric, self._where_layers(view, expression)
        )

    def _search_controlled(
        self,
        view: ReadGeneration,
        query: List[Float32],
        k: Int,
        metric: Int,
        control: QueryControl,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        var layers = self._visible_layers(view)
        var total = _total(layers)
        control.validate_candidate_count(total)
        control.checkpoint(0)
        if total == 0:
            return List[SearchResult]()
        var topk = BoundedTopK(
            min(k, total), smaller_is_better=metric == _L2_METRIC
        )
        var index = 0
        for layer in range(len(layers)):
            ref table = view.run(layer).memtable
            for ordinal in layers[layer]:
                control.checkpoint(index)
                index += 1
                ref entry = table.entry_ref_at(ordinal)
                topk.offer(entry.id, _score(metric, query, entry.values()))
        control.checkpoint(0)
        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def _search_parallel(
        self,
        view: ReadGeneration,
        query: List[Float32],
        k: Int,
        metric: Int,
        num_workers: Int,
        layers: List[List[Int]],
    ) raises -> List[SearchResult]:
        var parts = List[List[SearchResult]](capacity=len(layers))
        for layer in range(len(layers)):
            parts.append(
                execute_parallel_scan(
                    view.run(layer).memtable,
                    layers[layer],
                    query,
                    k,
                    metric,
                    num_workers,
                )
            )
        return _merge(parts, k, metric)

    def _search_where_parallel(
        self,
        view: ReadGeneration,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
        metric: Int,
        num_workers: Int,
    ) raises -> List[SearchResult]:
        expression.validate()
        return self._search_parallel(
            view,
            query,
            k,
            metric,
            num_workers,
            self._where_layers(view, expression),
        )

    def _search_batch(
        self,
        view: ReadGeneration,
        queries: List[List[Float32]],
        k: Int,
        metric: Int,
        num_workers: Int,
    ) raises -> List[List[SearchResult]]:
        var parts = List[List[List[SearchResult]]](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            parts.append(
                execute_exact_ordinal_batch(
                    view.run(layer).memtable,
                    queries,
                    view.visible_ordinals(layer),
                    k,
                    metric,
                    num_workers,
                )
            )
        return _merge_batch(parts, len(queries), k, metric)

    def _search_where_batch(
        self,
        view: ReadGeneration,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        metric: Int,
        num_workers: Int,
    ) raises -> List[List[SearchResult]]:
        if len(queries) != len(expressions):
            raise Error("batch query and filter counts must match")
        for index in range(len(expressions)):
            expressions[index].validate()
        var parts = List[List[List[SearchResult]]](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            var candidates = List[List[Int]](capacity=len(queries))
            for index in range(len(expressions)):
                candidates.append(
                    view.filtered_ordinals(layer, expressions[index])
                )
            parts.append(
                execute_exact_candidate_batch(
                    view.run(layer).memtable,
                    queries,
                    candidates,
                    k,
                    metric,
                    num_workers,
                )
            )
        return _merge_batch(parts, len(queries), k, metric)

    def _device_run(self, view: ReadGeneration) raises -> ArcPointer[ReadRun]:
        """Build the root's flat device table once, under its device lock."""
        with BlockingScopedLock(view.device[].lock):
            if not view.device[].table:
                view.device[].table = Optional(view.dense_run())
            return view.device[].table.value()

    def _search_device_batch[
        use_accelerator: Bool
    ](
        self,
        view: ReadGeneration,
        queries: List[List[Float32]],
        k: Int,
        metric: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var table = self._device_run(view)
        var candidates = List[List[Int]]()
        return execute_snapshot_device_batch[use_accelerator](
            table[].memtable,
            queries,
            candidates,
            False,
            k,
            metric,
            options,
            view.device[],
        )

    def _search_device_where_batch[
        use_accelerator: Bool
    ](
        self,
        view: ReadGeneration,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        metric: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        if len(queries) != len(expressions):
            raise Error("batch query and filter counts must match")
        var table = self._device_run(view)
        var candidates = List[List[Int]](capacity=len(queries))
        for index in range(len(expressions)):
            expressions[index].validate()
            var selected = List[Int]()
            for layer in range(view.layer_count()):
                ref source = view.run(layer).memtable
                # Visible rows map by public ID into the flat table's slots.
                for ordinal in view.filtered_ordinals(
                    layer, expressions[index]
                ):
                    selected.append(
                        table[].memtable.ordinal_for(source.id_at(ordinal))
                    )
            sort(Span(selected))
            candidates.append(selected^)
        return execute_snapshot_device_batch[use_accelerator](
            table[].memtable,
            queries,
            candidates,
            True,
            k,
            metric,
            options,
            view.device[],
        )

    def _visible_layers(self, view: ReadGeneration) raises -> List[List[Int]]:
        var layers = List[List[Int]](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            layers.append(view.visible_ordinals(layer))
        return layers^

    def _where_layers(
        self, view: ReadGeneration, expression: FilterExpression
    ) raises -> List[List[Int]]:
        """Evaluate a filter per run, then drop shadowed rows before Top-K."""
        var layers = List[List[Int]](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            layers.append(view.filtered_ordinals(layer, expression))
        return layers^

    def _gather(
        self,
        view: ReadGeneration,
        locations: List[Tuple[Int, Int]],
        mut ids: List[Int],
        mut vectors: List[List[Float32]],
    ) raises:
        for location in locations:
            ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
            ids.append(entry.id)
            vectors.append(entry.values().copy())

    def _scan(
        self,
        view: ReadGeneration,
        query: List[Float32],
        k: Int,
        metric: Int,
        layers: List[List[Int]],
    ) raises -> List[SearchResult]:
        var total = _total(layers)
        if total == 0:
            return List[SearchResult]()
        var topk = BoundedTopK(
            min(k, total), smaller_is_better=metric == _L2_METRIC
        )
        for layer in range(len(layers)):
            ref table = view.run(layer).memtable
            for ordinal in layers[layer]:
                ref entry = table.entry_ref_at(ordinal)
                topk.offer(entry.id, _score(metric, query, entry.values()))
        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def _validate_query(self, query: List[Float32], k: Int) raises:
        if len(query) != self._dimension:
            raise Error("query dimension does not match snapshot")
        if k <= 0:
            raise Error("k must be positive")
        for value in query:
            if not isfinite(value):
                raise Error("query vector must contain only finite values")

    def _validate_hybrid(
        self,
        dense_query: List[Float32],
        sparse_query: List[SparseElement],
        k: Int,
        fetch_k: Int,
        rank_constant: Int,
    ) raises:
        self._validate_query(dense_query, k)
        validate_sparse(sparse_query)
        if fetch_k < k:
            raise Error("hybrid fetch_k must be at least positive k")
        if rank_constant <= 0:
            raise Error("RRF rank constant must be positive")

    def _search_hybrid(
        self,
        view: ReadGeneration,
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
            view, dense_query, fetch_k, metric, conditions
        )
        var sparse = self._search_sparse(
            view, sparse_query, fetch_k, Optional[List[List[Int]]]()
        )
        return reciprocal_rank_fusion(dense, sparse, k, rank_constant)

    def _search_hybrid_where(
        self,
        view: ReadGeneration,
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
        var dense = self._search_where(
            view, dense_query, fetch_k, metric, expression
        )
        var sparse = self._search_sparse(
            view,
            sparse_query,
            fetch_k,
            Optional(self._where_layers(view, expression)),
        )
        return reciprocal_rank_fusion(dense, sparse, k, rank_constant)


def _score(
    metric: Int, query: List[Float32], values: List[Float32]
) raises -> Float32:
    if metric == _DOT_METRIC:
        return simd_dot_product(query, values)
    if metric == _L2_METRIC:
        return simd_l2_squared_distance(query, values)
    return simd_cosine_similarity(query, values)


def _total(layers: List[List[Int]]) -> Int:
    var total = 0
    for layer in layers:
        total += len(layer)
    return total


def _merge(
    parts: List[List[SearchResult]], k: Int, metric: Int
) raises -> List[SearchResult]:
    """Merge per-run exact Top-K lists; the heap's total order keeps it exact.
    """
    var total = 0
    for part in parts:
        total += len(part)
    if total == 0:
        return List[SearchResult]()
    var topk = BoundedTopK(
        min(k, total), smaller_is_better=metric == _L2_METRIC
    )
    for part in parts:
        for result in part:
            topk.offer(result.id, result.score)
    var retained = topk.sorted_entries()
    var results = List[SearchResult](capacity=len(retained))
    for entry in retained:
        results.append(SearchResult(entry.id, entry.score))
    return results^


def _merge_batch(
    parts: List[List[List[SearchResult]]], queries: Int, k: Int, metric: Int
) raises -> List[List[SearchResult]]:
    var output = List[List[SearchResult]](capacity=queries)
    if len(parts) == 0 or len(parts[0]) != queries:
        return output^
    for query in range(queries):
        var per_query = List[List[SearchResult]](capacity=len(parts))
        for layer in range(len(parts)):
            per_query.append(parts[layer][query].copy())
        output.append(_merge(per_query, k, metric))
    return output^
