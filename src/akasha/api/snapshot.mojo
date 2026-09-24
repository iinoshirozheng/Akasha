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
from akasha.compute.gpu.context import GpuSnapshotState
from akasha.document.record import (
    clone_fields,
    DocumentRecord,
    FieldProjection,
    project_document,
)
from akasha.index.bitmap import Bitmap
from akasha.index.flat import SearchResult
from akasha.index.quantization import PqIndex, Sq8Index
from akasha.index.sparse import (
    SparseElement,
    SparseIndex,
    SparseRecord,
    validate_sparse,
)
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
    execute_exact_ordinal_batch,
)
from akasha.storage.read_generation import ReadGeneration, ReadRun
from std.math import isfinite
from std.memory import ArcPointer
from std.utils import BlockingScopedLock


comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct ReadSnapshot(Movable):
    """An immutable, owned collection view at one accepted sequence."""

    var _config: CollectionConfig
    var _dimension: Int
    var _generation: UInt64
    var _sequence: UInt64
    var _root: Optional[ArcPointer[ReadGeneration]]
    var _gpu_state: ArcPointer[GpuSnapshotState]

    def __init__(out self, var root: ArcPointer[ReadGeneration]):
        self._config = root[].config.copy()
        self._dimension = root[].config.dimension
        self._generation = root[].generation
        self._sequence = root[].sequence
        # Device scratch/cache is still per handle. Closing a sibling must not
        # release another handle's GPU state merely because CPU data is shared.
        self._gpu_state = ArcPointer(GpuSnapshotState(self._generation, self._sequence))
        self._root = Optional(root^)

    def close(mut self):
        """Drop this handle's data owner and device state; idempotent."""
        if not self._root:
            return
        self._gpu_state[].release()
        self._root = Optional[ArcPointer[ReadGeneration]]()

    def _view(
        self,
    ) raises -> ref[origin_of(self._root.value()[], self)] ReadGeneration:
        # Union with immutable self makes the returned borrow readonly despite
        # ArcPointer's mutable dereference. No borrowed buffer escapes the API.
        self._ensure_open()
        return self._root.value()[]

    def generation(self) -> UInt64:
        return self._generation

    def last_sequence(self) -> UInt64:
        return self._sequence

    def collection_config(self) -> CollectionConfig:
        return self._config.copy()

    def config_fingerprint(self) -> UInt64:
        return self._config.fingerprint()

    def get(self, id: Int) raises -> Optional[DocumentRecord]:
        var location = self._view().find(id)
        if location[0] < 0:
            return Optional[DocumentRecord]()
        return Optional(self._record_at(location))

    def get_projected(
        self, id: Int, projection: FieldProjection
    ) raises -> Optional[DocumentRecord]:
        var document = self.get(id)
        if not Bool(document):
            return Optional[DocumentRecord]()
        return Optional(project_document(document.value(), projection))

    def documents(self) raises -> List[DocumentRecord]:
        """Return owned live records for logical export."""
        var locations = self._view().id_ordered_locations()
        var records = List[DocumentRecord](capacity=len(locations))
        for location in locations:
            records.append(self._record_at(location))
        return records^

    def sparse_records(self) raises -> List[SparseRecord]:
        """Return an owned sparse snapshot for logical export."""
        var source = self._view().sparse[].records()
        var records = List[SparseRecord](capacity=len(source))
        for index in range(len(source)):
            records.append(source[index].clone())
        return records^

    def _record_at(self, location: Tuple[Int, Int]) raises -> DocumentRecord:
        """Materialize an owned record; later mutation cannot reach the run."""
        ref entry = self._view().run(location[0]).memtable.entry_ref_at(
            location[1]
        )
        return DocumentRecord(
            entry.id,
            entry.sequence,
            entry.values().copy(),
            clone_fields(entry.fields),
        )

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
            query, k, _DOT_METRIC, num_workers, self._visible_layers()
        )

    def search_l2_parallel(
        self, query: List[Float32], k: Int, *, num_workers: Int = 0
    ) raises -> List[SearchResult]:
        return self._search_parallel(
            query, k, _L2_METRIC, num_workers, self._visible_layers()
        )

    def search_cosine_parallel(
        self, query: List[Float32], k: Int, *, num_workers: Int = 0
    ) raises -> List[SearchResult]:
        return self._search_parallel(
            query,
            k,
            _COSINE_METRIC,
            num_workers,
            self._visible_layers(),
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
        return self._search_batch(queries, k, BATCH_DOT_METRIC, num_workers)

    def search_l2_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        return self._search_batch(queries, k, BATCH_L2_METRIC, num_workers)

    def search_cosine_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        *,
        num_workers: Int = 0,
    ) raises -> List[List[SearchResult]]:
        return self._search_batch(queries, k, BATCH_COSINE_METRIC, num_workers)

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
        return self._view().sparse[].search_dot(query, k)

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
        ref view = self._view()
        var matched = List[Bitmap](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            matched.append(
                evaluate_expression(view.run(layer).metadata, expression)
            )
        var count = view.sparse[].point_count()
        if count == 0:
            return List[SearchResult]()
        var candidates = view.sparse[].search_dot(query, count)
        var result = List[SearchResult]()
        for candidate in candidates:
            # The newest point state decides the filter, in its own run.
            var location = view.find(candidate.id)
            if location[0] >= 0 and matched[location[0]].contains(location[1]):
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
        ref view = self._view()
        var layers = List[List[Int]](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            var bitmap = evaluate_all(view.run(layer).metadata, conditions)
            layers.append(view.candidate_ordinals(layer, bitmap))
        return self._scan(query, k, metric, layers)

    def _search_sq8(
        self, query: List[Float32], k: Int, rerank_k: Int, metric: Int
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        if rerank_k < 0 or (rerank_k > 0 and rerank_k < k):
            raise Error("SQ8 rerank candidate count must be zero or at least k")
        var ordinals = self._view().id_ordered_locations()
        if len(ordinals) == 0:
            return List[SearchResult]()
        var ids = List[Int](capacity=len(ordinals))
        var vectors = List[List[Float32]](capacity=len(ordinals))
        self._gather(ordinals, ids, vectors)
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

        return self._exact_rerank(query, k, metric, candidates)

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
        var ordinals = self._view().id_ordered_locations()
        if len(ordinals) == 0:
            return List[SearchResult]()
        var ids = List[Int](capacity=len(ordinals))
        var vectors = List[List[Float32]](capacity=len(ordinals))
        self._gather(ordinals, ids, vectors)
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
        return self._exact_rerank(query, k, metric, candidates)

    def _exact_rerank(
        self,
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
            var location = self._view().find(candidate.id)
            if location[0] < 0:
                raise Error("quantized candidate is absent from snapshot")
            ref entry = self._view().run(location[0]).memtable.entry_ref_at(
                location[1]
            )
            topk.offer(entry.id, _score(metric, query, entry.values()))
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
        return self._scan(query, k, metric, self._where_layers(expression))

    def _search_controlled(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        control: QueryControl,
    ) raises -> List[SearchResult]:
        self._validate_query(query, k)
        ref view = self._view()
        var layers = self._visible_layers()
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
        query: List[Float32],
        k: Int,
        metric: Int,
        num_workers: Int,
        layers: List[List[Int]],
    ) raises -> List[SearchResult]:
        ref view = self._view()
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
        query: List[Float32],
        k: Int,
        expression: FilterExpression,
        metric: Int,
        num_workers: Int,
    ) raises -> List[SearchResult]:
        self._ensure_open()
        expression.validate()
        return self._search_parallel(
            query, k, metric, num_workers, self._where_layers(expression)
        )

    def _search_batch(
        self,
        queries: List[List[Float32]],
        k: Int,
        metric: Int,
        num_workers: Int,
    ) raises -> List[List[SearchResult]]:
        ref view = self._view()
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
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        metric: Int,
        num_workers: Int,
    ) raises -> List[List[SearchResult]]:
        ref view = self._view()
        if len(queries) != len(expressions):
            raise Error("batch query and filter counts must match")
        for index in range(len(expressions)):
            expressions[index].validate()
        var parts = List[List[List[SearchResult]]](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            var candidates = List[List[Int]](capacity=len(queries))
            for index in range(len(expressions)):
                var bitmap = evaluate_expression(
                    view.run(layer).metadata, expressions[index]
                )
                candidates.append(view.candidate_ordinals(layer, bitmap))
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

    def _device_run(self) raises -> ArcPointer[ReadRun]:
        """Build this handle's flat device table once, under its GPU lock."""
        ref view = self._view()
        with BlockingScopedLock(self._gpu_state[].lock):
            if not self._gpu_state[].table:
                self._gpu_state[].table = Optional(view.dense_run())
            return self._gpu_state[].table.value()

    def _search_device_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        k: Int,
        metric: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        var table = self._device_run()
        var candidates = List[List[Int]]()
        return execute_snapshot_device_batch[use_accelerator](
            table[].memtable,
            queries,
            candidates,
            False,
            k,
            metric,
            options,
            self._gpu_state[],
        )

    def _search_device_where_batch[use_accelerator: Bool](
        self,
        queries: List[List[Float32]],
        expressions: List[FilterExpression],
        k: Int,
        metric: Int,
        options: GpuExecutionOptions,
    ) raises -> DeviceBatchResult:
        ref view = self._view()
        if len(queries) != len(expressions):
            raise Error("batch query and filter counts must match")
        var table = self._device_run()
        var candidates = List[List[Int]](capacity=len(queries))
        for index in range(len(expressions)):
            expressions[index].validate()
            var selected = List[Int]()
            for layer in range(view.layer_count()):
                ref source = view.run(layer).memtable
                var bitmap = evaluate_expression(
                    view.run(layer).metadata, expressions[index]
                )
                # Visible rows map by public ID into the flat table's slots.
                for ordinal in view.candidate_ordinals(layer, bitmap):
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
            self._gpu_state[],
        )

    def _visible_layers(self) raises -> List[List[Int]]:
        ref view = self._view()
        var layers = List[List[Int]](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            layers.append(view.visible_ordinals(layer))
        return layers^

    def _where_layers(
        self, expression: FilterExpression
    ) raises -> List[List[Int]]:
        """Evaluate a filter per run, then drop shadowed rows before Top-K."""
        ref view = self._view()
        var layers = List[List[Int]](capacity=view.layer_count())
        for layer in range(view.layer_count()):
            var bitmap = evaluate_expression(view.run(layer).metadata, expression)
            layers.append(view.candidate_ordinals(layer, bitmap))
        return layers^

    def _gather(
        self,
        locations: List[Tuple[Int, Int]],
        mut ids: List[Int],
        mut vectors: List[List[Float32]],
    ) raises:
        ref view = self._view()
        for location in locations:
            ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
            ids.append(entry.id)
            vectors.append(entry.values().copy())

    def _scan(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        layers: List[List[Int]],
    ) raises -> List[SearchResult]:
        var total = _total(layers)
        if total == 0:
            return List[SearchResult]()
        ref view = self._view()
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
        var sparse = self._view().sparse[].search_dot(sparse_query, fetch_k)
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
        if not self._root:
            raise Error("snapshot is closed")


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
    var topk = BoundedTopK(min(k, total), smaller_is_better=metric == _L2_METRIC)
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
