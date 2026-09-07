from akasha.compute.dispatch import (
    DistanceExecutionStats,
    portable_simd_width,
)
from akasha.compute.gpu.planner import (
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
from layout import TileTensor, TensorLayout, row_major
from std.gpu import global_idx
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


def _score_kernel[
    L: TensorLayout
](
    vectors: TileTensor[DType.float32, L, MutAnyOrigin],
    queries: TileTensor[DType.float32, L, MutAnyOrigin],
    scores: TileTensor[DType.float32, L, MutAnyOrigin],
    candidates: TileTensor[DType.int64, L, MutAnyOrigin],
    offsets: TileTensor[DType.int64, L, MutAnyOrigin],
    point_count: Int32,
    query_count: Int32,
    dimension: Int32,
    jobs: Int32,
    metric: Int32,
    filtered: Int32,
):
    comptime assert (
        vectors.flat_rank == 1
        and queries.flat_rank == 1
        and scores.flat_rank == 1
    )
    comptime assert candidates.flat_rank == 1 and offsets.flat_rank == 1
    var job = global_idx.x
    if job >= Int(jobs):
        return
    var query_index = job // Int(point_count)
    var point_index = job % Int(point_count)
    if filtered != 0:
        var left = 0
        var right = Int(query_count)
        while left < right:
            var mid = (left + right) // 2
            if Int(rebind[Int64](offsets[mid + 1])) <= job:
                left = mid + 1
            else:
                right = mid
        query_index = left
        point_index = Int(rebind[Int64](candidates[job]))
    var score: Float32 = 0.0
    var query_norm: Float32 = 0.0
    var point_norm: Float32 = 0.0
    for column in range(Int(dimension)):
        var query_value = rebind[Float32](
            queries[query_index * Int(dimension) + column]
        )
        var point_value = rebind[Float32](
            vectors[point_index * Int(dimension) + column]
        )
        if metric == Int32(BATCH_L2_METRIC):
            var delta = query_value - point_value
            score += delta * delta
        else:
            score += query_value * point_value
            if metric == Int32(BATCH_COSINE_METRIC):
                query_norm += query_value * query_value
                point_norm += point_value * point_value
    if metric == Int32(BATCH_COSINE_METRIC):
        score /= sqrt(query_norm) * sqrt(point_norm)
    scores[job] = rebind[scores.ElementType](score)


def _topk_kernel[
    L: TensorLayout
](
    scores: TileTensor[DType.float32, L, MutAnyOrigin],
    ids: TileTensor[DType.int64, L, MutAnyOrigin],
    candidates: TileTensor[DType.int64, L, MutAnyOrigin],
    offsets: TileTensor[DType.int64, L, MutAnyOrigin],
    output_ids: TileTensor[DType.int64, L, MutAnyOrigin],
    output_scores: TileTensor[DType.float32, L, MutAnyOrigin],
    query_count: Int32,
    result_stride: Int32,
    metric: Int32,
    filtered: Int32,
):
    comptime assert scores.flat_rank == 1 and ids.flat_rank == 1
    comptime assert candidates.flat_rank == 1 and offsets.flat_rank == 1
    comptime assert output_ids.flat_rank == 1 and output_scores.flat_rank == 1
    var query_index = global_idx.x
    if query_index >= Int(query_count):
        return
    var start = Int(rebind[Int64](offsets[query_index]))
    var end = Int(rebind[Int64](offsets[query_index + 1]))
    var output_start = query_index * Int(result_stride)
    for rank in range(min(Int(result_stride), end - start)):
        var best_point = -1
        var best_id: Int64 = 0
        var best_score: Float32 = 0.0
        for job in range(start, end):
            var position = (
                Int(rebind[Int64](candidates[job])) if filtered
                != 0 else job - start
            )
            var candidate_id = rebind[Int64](ids[position])
            var already_selected = False
            for previous in range(rank):
                if (
                    rebind[Int64](output_ids[output_start + previous])
                    == candidate_id
                ):
                    already_selected = True
                    break
            if already_selected:
                continue
            var candidate_score = rebind[Float32](scores[job])
            var better = best_point < 0
            if best_point >= 0:
                if candidate_score == best_score:
                    better = candidate_id < best_id
                elif metric == Int32(BATCH_L2_METRIC):
                    better = candidate_score < best_score
                else:
                    better = candidate_score > best_score
            if better:
                best_point = job
                best_id = candidate_id
                best_score = candidate_score
        output_ids[output_start + rank] = rebind[output_ids.ElementType](
            best_id
        )
        output_scores[output_start + rank] = rebind[output_scores.ElementType](
            best_score
        )


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
    if filtered:
        if len(candidates) != len(queries):
            raise Error("device query and candidate counts must match")
        candidate_count = 0
        for query_index in range(len(candidates)):
            if len(candidates[query_index]) > Int.MAX - candidate_count:
                raise Error("GPU candidate count overflows Int")
            candidate_count += len(candidates[query_index])
    var plan = plan_gpu_execution(
        use_accelerator and has_accelerator(),
        len(queries),
        memtable.live_count(),
        memtable.dimension,
        k,
        options,
        candidate_count=candidate_count,
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
    offsets.append(0)
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
    if not filtered and metric == BATCH_COSINE_METRIC:
        for norm in cache.point_norms:
            if norm == 0.0:
                raise Error("cosine similarity requires non-zero vectors")
    var jobs = offsets[len(offsets) - 1]
    if max(point_count, query_count, cache.dimension, jobs) > Int(Int32.MAX):
        raise Error("GPU query shape exceeds Int32 launch format")
    timings.preparation_ns += perf_counter_ns() - start
    cache.ensure_scratch(
        query_count,
        jobs,
        len(positions),
        query_count * result_stride,
        UInt64(options.memory_budget_bytes),
        timings,
    )
    ref scratch = cache.scratch.value()
    start = perf_counter_ns()
    with scratch.queries.map_to_host() as host:
        for query_index in range(query_count):
            for column in range(cache.dimension):
                host[query_index * cache.dimension + column] = queries[
                    query_index
                ][column]
    with scratch.offsets.map_to_host() as host:
        for index in range(len(offsets)):
            host[index] = Int64(offsets[index])
    if filtered:
        with scratch.candidates.map_to_host() as host:
            for index in range(len(positions)):
                host[index] = Int64(positions[index])
    timings.upload_ns += perf_counter_ns() - start
    timings.request_upload_bytes = (
        UInt64(query_count * cache.dimension) * 4
        + UInt64(len(offsets) + len(positions)) * 8
    )
    var vectors_tensor = TileTensor(
        cache.vectors, row_major(point_count * cache.dimension)
    )
    var queries_tensor = TileTensor(
        scratch.queries, row_major(query_count * cache.dimension)
    )
    var scores_tensor = TileTensor(scratch.scores, row_major(jobs))
    var candidates_tensor = TileTensor(
        scratch.candidates, row_major(max(1, len(positions)))
    )
    var offsets_tensor = TileTensor(scratch.offsets, row_major(query_count + 1))
    var ids_tensor = TileTensor(cache.ids, row_major(point_count))
    var output_ids_tensor = TileTensor(
        scratch.output_ids, row_major(query_count * result_stride)
    )
    var output_scores_tensor = TileTensor(
        scratch.output_scores, row_major(query_count * result_stride)
    )
    comptime score_kernel = _score_kernel[type_of(vectors_tensor.layout)]
    comptime topk_kernel = _topk_kernel[type_of(vectors_tensor.layout)]
    start = perf_counter_ns()
    cache.context.enqueue_function[score_kernel](
        vectors_tensor,
        queries_tensor,
        scores_tensor,
        candidates_tensor,
        offsets_tensor,
        Int32(point_count),
        Int32(query_count),
        Int32(cache.dimension),
        Int32(jobs),
        Int32(metric),
        Int32(filtered),
        grid_dim=ceildiv(jobs, options.block_size),
        block_dim=options.block_size,
    )
    if options.profile:
        cache.context.synchronize()
        timings.distance_ns = perf_counter_ns() - start
    start = perf_counter_ns()
    cache.context.enqueue_function[topk_kernel](
        scores_tensor,
        ids_tensor,
        candidates_tensor,
        offsets_tensor,
        output_ids_tensor,
        output_scores_tensor,
        Int32(query_count),
        Int32(result_stride),
        Int32(metric),
        Int32(filtered),
        grid_dim=ceildiv(query_count, options.block_size),
        block_dim=options.block_size,
    )
    cache.context.synchronize()
    if options.profile:
        timings.topk_ns = perf_counter_ns() - start
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
