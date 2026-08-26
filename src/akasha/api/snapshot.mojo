from akasha.compute.simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
from akasha.compute.topk import BoundedTopK
from akasha.compute.gpu.flat_scan import (
    DeviceBatchResult,
    execute_device_batch,
    execute_device_candidate_batch,
)
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.document.record import (
    clone_fields,
    DocumentRecord,
    FieldProjection,
    project_document,
)
from akasha.index.bitmap import Bitmap
from akasha.index.flat import SearchResult
from akasha.index.metadata import MetadataIndex
from akasha.index.quantization import PqIndex, Sq8Index
from akasha.index.sparse import SparseElement, SparseIndex, validate_sparse
from akasha.query.executor import candidate_entries
from akasha.query.control import QueryControl
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.fusion import reciprocal_rank_fusion
from akasha.query.index_evaluator import evaluate_all, evaluate_expression
from akasha.query.parallel_scan import execute_parallel_scan
from akasha.query.batch_executor import (
    BATCH_COSINE_METRIC,
    BATCH_DOT_METRIC,
    BATCH_L2_METRIC,
    execute_exact_candidate_batch,
    execute_exact_batch,
)
from akasha.storage.memtable import MemTable, MemTableEntry
from akasha.storage.generation_pins import GenerationPinRegistry
from std.math import isfinite
from std.memory import ArcPointer


comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct ReadSnapshot(Movable):
    """An immutable, owned collection view at one accepted sequence."""

    var _dimension: Int
    var _generation: UInt64
    var _sequence: UInt64
    var _memtable: MemTable
    var _metadata: MetadataIndex
    var _sparse: SparseIndex
    var _pins: ArcPointer[GenerationPinRegistry]
    var _closed: Bool

    def __init__(
        out self,
        dimension: Int,
        generation: UInt64,
        sequence: UInt64,
        var memtable: MemTable,
        var metadata: MetadataIndex,
        var sparse: SparseIndex,
        var pins: ArcPointer[GenerationPinRegistry],
    ):
        self._dimension = dimension
        self._generation = generation
        self._sequence = sequence
        self._memtable = memtable^
        self._metadata = metadata^
        self._sparse = sparse^
        self._pins = pins^
        self._closed = False

    @staticmethod
    def capture(
        dimension: Int,
        generation: UInt64,
        sequence: UInt64,
        memtable: MemTable,
        sparse: SparseIndex,
        pins: ArcPointer[GenerationPinRegistry],
    ) raises -> ReadSnapshot:
        if dimension <= 0 or memtable.dimension != dimension:
            raise Error("snapshot dimension mismatch")
        if memtable.last_sequence > sequence:
            raise Error("snapshot sequence precedes memtable")
        var owned = memtable.clone()
        var metadata = _build_metadata(owned)
        var owned_sparse = sparse.clone()
        var owned_pins = pins
        owned_pins[].pin(generation)
        return ReadSnapshot(
            dimension,
            generation,
            sequence,
            owned^,
            metadata^,
            owned_sparse^,
            owned_pins^,
        )

    def __deinit__(deinit self):
        if not self._closed:
            self._pins[].unpin(self._generation)

    def close(mut self):
        """Release the manifest generation pin; safe to call repeatedly."""
        if self._closed:
            return
        self._pins[].unpin(self._generation)
        self._closed = True

    def generation(self) -> UInt64:
        return self._generation

    def last_sequence(self) -> UInt64:
        return self._sequence

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        self._ensure_open()
        return self._memtable.get(id)

    def get_projected(
        self, id: Int, projection: FieldProjection
    ) raises -> Optional[DocumentRecord]:
        self._ensure_open()
        var document = self._memtable.get(id)
        if not Bool(document):
            return Optional[DocumentRecord]()
        return Optional(project_document(document.value(), projection))

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

    def search_dot_controlled(
        self, query: List[Float32], k: Int, control: QueryControl
    ) raises -> List[SearchResult]:
        return self._search_controlled(query, k, _DOT_METRIC, control)

    def search_l2_controlled(
        self, query: List[Float32], k: Int, control: QueryControl
    ) raises -> List[SearchResult]:
        return self._search_controlled(query, k, _L2_METRIC, control)

    def search_cosine_controlled(
        self, query: List[Float32], k: Int, control: QueryControl
    ) raises -> List[SearchResult]:
        return self._search_controlled(query, k, _COSINE_METRIC, control)

    def search_dot_parallel(
        self, query: List[Float32], k: Int, *, num_workers: Int = 0
    ) raises -> List[SearchResult]:
        return self._search_parallel(
            query, k, _DOT_METRIC, num_workers, self._memtable.live_entries()
        )

    def search_l2_parallel(
        self, query: List[Float32], k: Int, *, num_workers: Int = 0
    ) raises -> List[SearchResult]:
        return self._search_parallel(
            query, k, _L2_METRIC, num_workers, self._memtable.live_entries()
        )

    def search_cosine_parallel(
        self, query: List[Float32], k: Int, *, num_workers: Int = 0
    ) raises -> List[SearchResult]:
        return self._search_parallel(
            query,
            k,
            _COSINE_METRIC,
            num_workers,
            self._memtable.live_entries(),
        )

    def search_sq8_dot(
        self, query: List[Float32], k: Int, *, rerank_k: Int = 0
    ) raises -> List[SearchResult]:
        """Search an immutable SQ8 view and optionally exact-rerank candidates."""
        return self._search_sq8(query, k, rerank_k, _DOT_METRIC)

    def search_sq8_l2(
        self, query: List[Float32], k: Int, *, rerank_k: Int = 0
    ) raises -> List[SearchResult]:
        return self._search_sq8(query, k, rerank_k, _L2_METRIC)

    def search_sq8_cosine(
        self, query: List[Float32], k: Int, *, rerank_k: Int = 0
    ) raises -> List[SearchResult]:
        return self._search_sq8(query, k, rerank_k, _COSINE_METRIC)

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
        return self._search_pq(
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
        return self._search_pq(
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
        return self._search_pq(
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
        self._ensure_open()
        return execute_exact_batch(
            self._memtable, queries, k, BATCH_DOT_METRIC, num_workers
        )

    def search_l2_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        self._ensure_open()
        return execute_exact_batch(
            self._memtable, queries, k, BATCH_L2_METRIC, num_workers
        )

    def search_cosine_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        self._ensure_open()
        return execute_exact_batch(
            self._memtable, queries, k, BATCH_COSINE_METRIC, num_workers
        )

    def search_device_dot_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        return self._search_device_batch[use_accelerator](
            queries, k, BATCH_DOT_METRIC, options
        )

    def search_device_l2_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        return self._search_device_batch[use_accelerator](
            queries, k, BATCH_L2_METRIC, options
        )

    def search_device_cosine_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        return self._search_device_batch[use_accelerator](
            queries, k, BATCH_COSINE_METRIC, options
        )

    def search_dot_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        return self._search_where_batch(
            queries, expressions, k, BATCH_DOT_METRIC, num_workers
        )

    def search_l2_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        return self._search_where_batch(
            queries, expressions, k, BATCH_L2_METRIC, num_workers
        )

    def search_cosine_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        return self._search_where_batch(
            queries, expressions, k, BATCH_COSINE_METRIC, num_workers
        )

    def search_device_dot_where_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        return self._search_device_where_batch[use_accelerator](
            queries, expressions, k, BATCH_DOT_METRIC, options
        )

    def search_device_l2_where_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        return self._search_device_where_batch[use_accelerator](
            queries, expressions, k, BATCH_L2_METRIC, options
        )

    def search_device_cosine_where_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        return self._search_device_where_batch[use_accelerator](
            queries, expressions, k, BATCH_COSINE_METRIC, options
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

    def search_dot_where_parallel(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
        *,
        num_workers: Int = 0,
    ) raises -> List[SearchResult]:
        return self._search_where_parallel(
            query, k, expression, _DOT_METRIC, num_workers
        )

    def search_l2_where_parallel(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
        *,
        num_workers: Int = 0,
    ) raises -> List[SearchResult]:
        return self._search_where_parallel(
            query, k, expression, _L2_METRIC, num_workers
        )

    def search_cosine_where_parallel(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
        *,
        num_workers: Int = 0,
    ) raises -> List[SearchResult]:
        return self._search_where_parallel(
            query, k, expression, _COSINE_METRIC, num_workers
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

    def _search_filtered(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        conditions: List[FilterCondition],
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        for index in range(len(conditions)):
            conditions[index].validate()
        var candidates = evaluate_all(self._metadata, conditions)
        return self._search_candidates(query, k, metric, candidates)

    def _search_sq8(
        self, query: List[Float32], k: Int, rerank_k: Int, metric: Int
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        if rerank_k < 0 or (rerank_k > 0 and rerank_k < k):
            raise Error("SQ8 rerank candidate count must be zero or at least k")
        var entries = self._memtable.live_entries()
        if len(entries) == 0:
            return List[SearchResult]()
        var ids = List[Int](capacity=len(entries))
        var vectors = List[List[Float32]](capacity=len(entries))
        for index in range(len(entries)):
            ids.append(entries[index].id)
            vectors.append(entries[index].values.copy())
        var sq8 = Sq8Index.build(ids, vectors)
        var candidate_count = k if rerank_k == 0 else rerank_k
        candidate_count = min(candidate_count, len(entries))
        var candidates: List[SearchResult]
        if metric == _DOT_METRIC:
            candidates = sq8.search_dot(query, candidate_count)
        elif metric == _L2_METRIC:
            candidates = sq8.search_l2(query, candidate_count)
        else:
            candidates = sq8.search_cosine(query, candidate_count)
        if rerank_k == 0:
            return candidates^

        return self._exact_rerank(query, k, metric, candidates, entries)

    def _search_pq(
        self,
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
        var entries = self._memtable.live_entries()
        if len(entries) == 0:
            return List[SearchResult]()
        var ids = List[Int](capacity=len(entries))
        var vectors = List[List[Float32]](capacity=len(entries))
        for index in range(len(entries)):
            ids.append(entries[index].id)
            vectors.append(entries[index].values.copy())
        var pq = PqIndex.build(
            ids,
            vectors,
            subquantizers,
            centroids,
            iterations=iterations,
        )
        var candidate_count = k if rerank_k == 0 else rerank_k
        candidate_count = min(candidate_count, len(entries))
        var candidates: List[SearchResult]
        if metric == _DOT_METRIC:
            candidates = pq.search_dot(query, candidate_count)
        elif metric == _L2_METRIC:
            candidates = pq.search_l2(query, candidate_count)
        else:
            candidates = pq.search_cosine(query, candidate_count)
        if rerank_k == 0:
            return candidates^
        return self._exact_rerank(query, k, metric, candidates, entries)

    def _exact_rerank(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        candidates: List[SearchResult],
        entries: List[MemTableEntry],
    ) raises -> List[SearchResult]:

        var topk = BoundedTopK(
            min(k, len(candidates)),
            smaller_is_better=metric == _L2_METRIC,
        )
        for candidate in candidates:
            for entry_index in range(len(entries)):
                if entries[entry_index].id != candidate.id:
                    continue
                var score: Float32
                if metric == _DOT_METRIC:
                    score = simd_dot_product(
                        query, entries[entry_index].values
                    )
                elif metric == _L2_METRIC:
                    score = simd_l2_squared_distance(
                        query, entries[entry_index].values
                    )
                else:
                    score = simd_cosine_similarity(
                        query, entries[entry_index].values
                    )
                topk.offer(entries[entry_index].id, score)
                break
        var retained = topk.sorted_entries()
        var output = List[SearchResult](capacity=len(retained))
        for entry in retained:
            output.append(SearchResult(entry.id, entry.score))
        return output^

    def _search_where(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        expression: FilterExpression,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        expression.validate()
        var candidates = evaluate_expression(self._metadata, expression)
        return self._search_candidates(query, k, metric, candidates)

    def _search_controlled(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        control: QueryControl,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        var entries = self._memtable.live_entries()
        control.validate_candidate_count(len(entries))
        control.checkpoint(0)
        if len(entries) == 0:
            return List[SearchResult]()
        var topk = BoundedTopK(
            min(k, len(entries)), smaller_is_better=metric == _L2_METRIC
        )
        for index in range(len(entries)):
            control.checkpoint(index)
            var score: Float32
            if metric == _DOT_METRIC:
                score = simd_dot_product(query, entries[index].values)
            elif metric == _L2_METRIC:
                score = simd_l2_squared_distance(query, entries[index].values)
            else:
                score = simd_cosine_similarity(query, entries[index].values)
            topk.offer(entries[index].id, score)
        control.checkpoint(0)
        var retained = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        return results^

    def _search_parallel(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        num_workers: Int,
        var entries: List[MemTableEntry],
    ) raises -> List[SearchResult]:
        self._ensure_open()
        var batch_metric = BATCH_DOT_METRIC
        if metric == _L2_METRIC:
            batch_metric = BATCH_L2_METRIC
        elif metric == _COSINE_METRIC:
            batch_metric = BATCH_COSINE_METRIC
        return execute_parallel_scan(
            self._dimension, entries, query, k, batch_metric, num_workers
        )

    def _search_where_parallel(
        self,
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
        metric: Int,
        num_workers: Int,
    ) raises -> List[SearchResult]:
        self._ensure_open()
        expression.validate()
        var bitmap = evaluate_expression(self._metadata, expression)
        var entries = candidate_entries(self._memtable, bitmap)
        return self._search_parallel(query, k, metric, num_workers, entries^)

    def _search_where_batch(
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        metric: Int,
        num_workers: Int,
    ) raises -> List[List[SearchResult]]:
        self._ensure_open()
        if len(queries) != len(expressions):
            raise Error("batch query and filter counts must match")
        var candidates = List[List[MemTableEntry]](capacity=len(queries))
        for index in range(len(expressions)):
            expressions[index].validate()
            var bitmap = evaluate_expression(self._metadata, expressions[index])
            candidates.append(candidate_entries(self._memtable, bitmap))
        return execute_exact_candidate_batch(
            self._dimension,
            queries,
            candidates,
            k,
            metric,
            num_workers,
        )

    def _search_device_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        k: Int,
        metric: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        self._ensure_open()
        return execute_device_batch[use_accelerator](
            self._memtable, queries, k, metric, options
        )

    def _search_device_where_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        metric: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        self._ensure_open()
        if len(queries) != len(expressions):
            raise Error("batch query and filter counts must match")
        var candidates = List[List[MemTableEntry]](capacity=len(queries))
        for index in range(len(expressions)):
            expressions[index].validate()
            var bitmap = evaluate_expression(self._metadata, expressions[index])
            candidates.append(candidate_entries(self._memtable, bitmap))
        return execute_device_candidate_batch[use_accelerator](
            self._dimension, queries, candidates, k, metric, options
        )

    def _search_candidates(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        candidates: Bitmap,
    ) raises -> List[SearchResult]:
        if candidates.count() == 0:
            return List[SearchResult]()
        var result_count = min(k, candidates.count())
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

    def _validate_query(self, query: List[Float32], k: Int) raises:
        self._ensure_open()
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
        var dense = self._search_where(
            dense_query, fetch_k, metric, expression
        )
        var sparse = self.search_sparse_dot_where(
            sparse_query, fetch_k, expression
        )
        return reciprocal_rank_fusion(dense, sparse, k, rank_constant)

    def _ensure_open(self) raises:
        if self._closed:
            raise Error("snapshot is closed")


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
        raise Error("snapshot metadata slot alignment failed")
    return index^
