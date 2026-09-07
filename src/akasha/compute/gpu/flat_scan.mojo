from akasha.compute.dispatch import (
    DistanceExecutionStats,
    portable_simd_width,
)
from akasha.compute.gpu.planner import (
    GPU_TILE_POINTS,
    GpuExecutionOptions,
    GpuPlan,
    plan_gpu_execution,
)
from akasha.compute.gpu.context import (
    GpuExecutionTimings,
    GpuSnapshotCache,
    GpuSnapshotState,
)
from akasha.index.flat import SearchResult
from akasha.query.batch_executor import (
    BATCH_COSINE_METRIC,
    BATCH_DOT_METRIC,
    BATCH_L2_METRIC,
    batch_metric_name,
    execute_exact_batch,
    execute_exact_candidate_batch,
)
from akasha.storage.memtable import MemTable
from layout import TileTensor, row_major
from akasha.compute.gpu.kernels import distance_partial_topk, merge_partial_topk
from std.math import ceildiv, isfinite, sqrt
from std.sys import has_accelerator
from std.time import perf_counter_ns
from std.utils import BlockingScopedLock


struct DeviceBatchResult(Movable):
    """Batch results plus whether an accelerator actually produced them."""

    var results: List[List[SearchResult]]
    var used_gpu: Bool
    var reason: String
    var required_bytes: UInt64
    var stats: DistanceExecutionStats
    var timings: GpuExecutionTimings

    def __init__(
        out self,
        var results: List[List[SearchResult]],
        used_gpu: Bool,
        reason: String,
        required_bytes: UInt64,
        var stats: DistanceExecutionStats,
    ):
        self.results = results^
        self.used_gpu = used_gpu
        self.reason = String(copy=reason)
        self.required_bytes = required_bytes
        self.stats = stats^
        self.timings = GpuExecutionTimings()

    def take_results(mut self) -> List[List[SearchResult]]:
        var replacement = List[List[SearchResult]]()
        var result = self.results^
        self.results = replacement^
        return result^


def _execution_stats(
    metric: Int,
    reason: String,
    used_gpu: Bool,
    evaluations: Int,
) raises -> DistanceExecutionStats:
    var backend_name = String("gpu")
    var fallback_reason = String()
    if not used_gpu:
        backend_name = String("portable-simd-", portable_simd_width())
        fallback_reason = String(copy=reason)
    return DistanceExecutionStats(
        backend_name^,
        batch_metric_name(metric),
        "f32",
        fallback_reason^,
        0,
        0,
        evaluations,
        evaluations,
    )


def _candidate_execution_stats(
    metric: Int,
    reason: String,
    any_gpu: Bool,
    any_cpu: Bool,
    evaluations: Int,
) raises -> DistanceExecutionStats:
    """Construct deterministic aggregate labels without requiring a device."""
    var stats = _execution_stats(
        metric, reason, any_gpu and not any_cpu, evaluations
    )
    if any_gpu and any_cpu:
        stats.backend_name = "mixed"
        stats.fallback_reason = String(copy=reason)
    return stats^


def execute_device_batch[
    use_accelerator: Bool
](
    memtable: MemTable,
    queries: List[List[Float32]],
    k: Int,
    metric: Int,
    options: GpuExecutionOptions,
) raises -> DeviceBatchResult:
    """Execute a mutable table once; persistent reuse belongs to a snapshot."""
    var state = GpuSnapshotState(sequence=memtable.last_sequence)
    var candidates = List[List[Int]]()
    return execute_snapshot_device_batch[use_accelerator](
        memtable, queries, candidates, False, k, metric, options, state
    )


def execute_device_candidate_batch[
    use_accelerator: Bool
](
    memtable: MemTable,
    queries: List[List[Float32]],
    candidates: List[List[Int]],
    k: Int,
    metric: Int,
    options: GpuExecutionOptions,
) raises -> DeviceBatchResult:
    var state = GpuSnapshotState(sequence=memtable.last_sequence)
    return execute_snapshot_device_batch[use_accelerator](
        memtable, queries, candidates, True, k, metric, options, state
    )


def execute_snapshot_device_batch[
    use_accelerator: Bool
](
    memtable: MemTable,
    queries: List[List[Float32]],
    candidates: List[List[Int]],
    filtered: Bool,
    k: Int,
    metric: Int,
    options: GpuExecutionOptions,
    mut state: GpuSnapshotState,
) raises -> DeviceBatchResult:
    """Use only with the immutable table owned alongside this snapshot state."""
    var total_start = perf_counter_ns()
    var candidate_count = -1
    var candidate_tiles = -1
    if filtered:
        if len(candidates) != len(queries):
            raise Error("device query and candidate counts must match")
        candidate_count = 0
        candidate_tiles = 0
        for query_index in range(len(candidates)):
            if len(candidates[query_index]) > Int.MAX - candidate_count:
                raise Error("GPU candidate count overflows Int")
            candidate_count += len(candidates[query_index])
            candidate_tiles += ceildiv(
                len(candidates[query_index]), GPU_TILE_POINTS
            )
    var plan = plan_gpu_execution(
        use_accelerator and has_accelerator(),
        len(queries),
        memtable.live_count(),
        memtable.dimension,
        k,
        options,
        candidate_count=candidate_count,
        candidate_tiles=candidate_tiles,
    )
    if not plan.use_gpu:
        state.trim_to_budget(UInt64(options.memory_budget_bytes))
        return _cpu_fallback(
            memtable, queries, candidates, filtered, k, metric, plan
        )
    comptime if use_accelerator and has_accelerator():
        with BlockingScopedLock(state.lock):
            var timings = GpuExecutionTimings()
            timings.generation = state.generation
            timings.sequence = state.sequence
            var start = perf_counter_ns()
            _validate_gpu_inputs(
                memtable, queries, candidates, filtered, k, metric
            )
            timings.preparation_ns += perf_counter_ns() - start
            try:
                if options.fail_before_launch:
                    raise Error("injected GPU launch failure")
                timings.cache_hit = Bool(state.cache)
                if not state.cache:
                    state.cache = Optional(GpuSnapshotCache(memtable, timings))
                var results = _execute_gpu_batch(
                    state.cache.value(),
                    queries,
                    candidates,
                    filtered,
                    k,
                    metric,
                    options,
                    timings,
                )
                var evaluations = (
                    candidate_count if filtered else len(queries)
                    * memtable.live_count()
                )
                var result = DeviceBatchResult(
                    results^,
                    True,
                    "gpu executed",
                    plan.required_bytes,
                    _execution_stats(metric, "", True, evaluations),
                )
                timings.total_ns = perf_counter_ns() - total_start
                result.timings = timings^
                return result^
            except error:
                # A failed stream is never reused by a later query.
                state.cache = Optional[GpuSnapshotCache]()
                plan.reason = "gpu failure: " + String(error)
                return _cpu_fallback(
                    memtable, queries, candidates, filtered, k, metric, plan
                )
    else:
        return _cpu_fallback(
            memtable, queries, candidates, filtered, k, metric, plan
        )


def _cpu_fallback(
    memtable: MemTable,
    queries: List[List[Float32]],
    candidates: List[List[Int]],
    filtered: Bool,
    k: Int,
    metric: Int,
    plan: GpuPlan,
) raises -> DeviceBatchResult:
    var results: List[List[SearchResult]]
    var evaluations = 0
    if filtered:
        results = execute_exact_candidate_batch(
            memtable, queries, candidates, k, metric, 0
        )
        for query_index in range(len(candidates)):
            evaluations += len(candidates[query_index])
    else:
        results = execute_exact_batch(memtable, queries, k, metric, 0)
        evaluations = len(queries) * memtable.live_count()
    return DeviceBatchResult(
        results^,
        False,
        plan.reason,
        plan.required_bytes,
        _execution_stats(metric, plan.reason, False, evaluations),
    )


def _execute_gpu_batch(
    mut cache: GpuSnapshotCache,
    queries: List[List[Float32]],
    candidates: List[List[Int]],
    filtered: Bool,
    k: Int,
    metric: Int,
    options: GpuExecutionOptions,
    mut timings: GpuExecutionTimings,
) raises -> List[List[SearchResult]]:
    var point_count = cache.point_count
    var query_count = len(queries)
    var result_stride = min(k, point_count)
    var start = perf_counter_ns()
    var offsets = List[Int](capacity=query_count + 1)
    var positions = List[Int]()
    var tile_offsets = List[Int](capacity=query_count + 1)
    offsets.append(0)
    tile_offsets.append(0)
    for query_index in range(query_count):
        if filtered:
            for ordinal in candidates[query_index]:
                var position = cache.positions[ordinal]
                if (
                    metric == BATCH_COSINE_METRIC
                    and cache.point_norms[position] == 0.0
                ):
                    raise Error("cosine similarity requires non-zero vectors")
                positions.append(position)
            offsets.append(len(positions))
        else:
            offsets.append((query_index + 1) * point_count)
        tile_offsets.append(
            tile_offsets[query_index]
            + ceildiv(
                offsets[query_index + 1] - offsets[query_index], GPU_TILE_POINTS
            )
        )
    if not filtered and metric == BATCH_COSINE_METRIC:
        for norm in cache.point_norms:
            if norm == 0.0:
                raise Error("cosine similarity requires non-zero vectors")
    var jobs = offsets[len(offsets) - 1]
    if max(point_count, query_count, cache.dimension, jobs) > Int(Int32.MAX):
        raise Error("GPU query shape exceeds Int32 launch format")
    timings.preparation_ns += perf_counter_ns() - start
    var tile_count = tile_offsets[query_count]
    var partial_stride = min(result_stride, GPU_TILE_POINTS)
    cache.ensure_scratch(
        query_count,
        tile_count * partial_stride,
        len(positions),
        query_count * result_stride,
        UInt64(options.memory_budget_bytes),
        timings,
    )
    ref scratch = cache.scratch.value()
    start = perf_counter_ns()
    with scratch.queries.map_to_host() as host:
        for query_index in range(query_count):
            var norm: Float32 = 0.0
            for column in range(cache.dimension):
                var value = queries[query_index][column]
                host[query_index * cache.dimension + column] = value
                norm += value * value
            if not isfinite(norm):
                raise Error("GPU query norm exceeds finite F32 accumulation")
            host[query_count * cache.dimension + query_index] = sqrt(norm)
    with scratch.offsets.map_to_host() as host:
        for index in range(len(offsets)):
            host[index] = Int64(offsets[index])
    with scratch.tile_offsets.map_to_host() as host:
        for index in range(len(tile_offsets)):
            host[index] = Int64(tile_offsets[index])
    if filtered:
        with scratch.candidates.map_to_host() as host:
            for index in range(len(positions)):
                host[index] = Int64(positions[index])
    timings.upload_ns += perf_counter_ns() - start
    timings.request_upload_bytes = (
        UInt64(query_count * (cache.dimension + 1)) * 4
        + UInt64(len(offsets) + len(tile_offsets) + len(positions)) * 8
    )
    if metric == BATCH_DOT_METRIC:
        _launch_gpu[0](
            cache,
            query_count,
            tile_count,
            partial_stride,
            result_stride,
            len(positions),
            filtered,
            options,
            timings,
        )
    elif metric == BATCH_L2_METRIC:
        _launch_gpu[1](
            cache,
            query_count,
            tile_count,
            partial_stride,
            result_stride,
            len(positions),
            filtered,
            options,
            timings,
        )
    else:
        _launch_gpu[2](
            cache,
            query_count,
            tile_count,
            partial_stride,
            result_stride,
            len(positions),
            filtered,
            options,
            timings,
        )
    start = perf_counter_ns()
    var output = List[List[SearchResult]](capacity=query_count)
    with scratch.output_ids.map_to_host() as ids:
        with scratch.output_scores.map_to_host() as scores:
            for query_index in range(query_count):
                var count = min(
                    result_stride,
                    offsets[query_index + 1] - offsets[query_index],
                )
                var results = List[SearchResult](capacity=count)
                for rank in range(count):
                    var index = query_index * result_stride + rank
                    results.append(SearchResult(Int(ids[index]), scores[index]))
                output.append(results^)
    timings.download_ns += perf_counter_ns() - start
    return output^


def _launch_gpu[
    metric: Int
](
    cache: GpuSnapshotCache,
    query_count: Int,
    tile_count: Int,
    partial_stride: Int,
    result_stride: Int,
    positions: Int,
    filtered: Bool,
    options: GpuExecutionOptions,
    mut timings: GpuExecutionTimings,
) raises:
    ref scratch = cache.scratch.value()
    # DeviceBuffer copies retain native handles, without allocating device storage.
    var vectors_buffer = cache.vectors
    var ids_buffer = cache.ids
    var queries_buffer = scratch.queries
    var candidates_buffer = scratch.candidates
    var offsets_buffer = scratch.offsets
    var tile_offsets_buffer = scratch.tile_offsets
    var partial_ids_buffer = scratch.partial_ids
    var partial_scores_buffer = scratch.partial_scores
    var output_ids_buffer = scratch.output_ids
    var output_scores_buffer = scratch.output_scores
    var vectors = TileTensor(
        vectors_buffer, row_major(cache.point_count * (cache.dimension + 1))
    )
    var queries = TileTensor(
        queries_buffer, row_major(query_count * (cache.dimension + 1))
    )
    var ids = TileTensor(ids_buffer, row_major(cache.point_count))
    var candidates = TileTensor(candidates_buffer, row_major(max(1, positions)))
    var offsets = TileTensor(offsets_buffer, row_major(query_count + 1))
    var tile_offsets = TileTensor(
        tile_offsets_buffer, row_major(query_count + 1)
    )
    var partial_ids = TileTensor(
        partial_ids_buffer, row_major(tile_count * partial_stride)
    )
    var partial_scores = TileTensor(
        partial_scores_buffer, row_major(tile_count * partial_stride)
    )
    var output_ids = TileTensor(
        output_ids_buffer, row_major(query_count * result_stride)
    )
    var output_scores = TileTensor(
        output_scores_buffer, row_major(query_count * result_stride)
    )
    comptime partial_kernel = distance_partial_topk[
        metric, type_of(vectors.layout)
    ]
    comptime merge_kernel = merge_partial_topk[metric, type_of(vectors.layout)]
    var start = perf_counter_ns()
    cache.context.enqueue_function[partial_kernel](
        vectors,
        queries,
        ids,
        candidates,
        offsets,
        tile_offsets,
        partial_ids,
        partial_scores,
        Int32(cache.point_count),
        Int32(query_count),
        Int32(cache.dimension),
        Int32(partial_stride),
        Int32(filtered),
        grid_dim=tile_count,
        block_dim=options.block_size,
    )
    if options.profile:
        cache.context.synchronize()
        timings.distance_ns = perf_counter_ns() - start
    start = perf_counter_ns()
    cache.context.enqueue_function[merge_kernel](
        partial_ids,
        partial_scores,
        offsets,
        tile_offsets,
        output_ids,
        output_scores,
        Int32(result_stride),
        Int32(partial_stride),
        grid_dim=query_count,
        block_dim=options.block_size,
    )
    cache.context.synchronize()
    if options.profile:
        timings.topk_ns = perf_counter_ns() - start


def _validate_gpu_inputs(
    memtable: MemTable,
    queries: List[List[Float32]],
    candidates: List[List[Int]],
    filtered: Bool,
    k: Int,
    metric: Int,
) raises:
    if k <= 0:
        raise Error("k must be positive")
    _ = batch_metric_name(metric)
    for query_index in range(len(queries)):
        if len(queries[query_index]) != memtable.dimension:
            raise Error("query dimension does not match snapshot")
        var norm: Float32 = 0.0
        for value in queries[query_index]:
            if not isfinite(value):
                raise Error("query vector must contain only finite values")
            norm += value * value
        if metric == BATCH_COSINE_METRIC and norm == 0.0:
            raise Error("cosine similarity requires non-zero vectors")
        if filtered:
            var previous = -1
            for ordinal in candidates[query_index]:
                if ordinal <= previous or not memtable.is_live_at(ordinal):
                    raise Error(
                        "device candidates must be increasing live ordinals"
                    )
                previous = ordinal
