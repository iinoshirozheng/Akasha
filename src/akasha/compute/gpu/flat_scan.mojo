from akasha.compute.dispatch import (
    DistanceExecutionStats,
    portable_simd_width,
)
from akasha.compute.gpu.planner import (
    GpuExecutionOptions,
    GpuPlan,
    plan_gpu_execution,
)
from akasha.index.flat import SearchResult
from akasha.query.batch_executor import (
    BATCH_COSINE_METRIC,
    BATCH_DOT_METRIC,
    BATCH_L2_METRIC,
    batch_metric_name,
    execute_exact_batch,
)
from akasha.storage.memtable import MemTable
from akasha.storage.memtable import MemTableEntry
from layout import TileTensor, TensorLayout, row_major
from max.gpu.host import DeviceContext
from std.gpu import global_idx
from std.math import ceildiv, isfinite, sqrt
from std.sys import has_accelerator


struct DeviceBatchResult(Movable):
    """Batch results plus whether an accelerator actually produced them."""

    var results: List[List[SearchResult]]
    var used_gpu: Bool
    var reason: String
    var required_bytes: UInt64
    var stats: DistanceExecutionStats

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


def _score_kernel[
    VectorsLayout: TensorLayout,
    QueriesLayout: TensorLayout,
    ScoresLayout: TensorLayout,
](
    vectors: TileTensor[DType.float32, VectorsLayout, MutAnyOrigin],
    queries: TileTensor[DType.float32, QueriesLayout, MutAnyOrigin],
    scores: TileTensor[DType.float32, ScoresLayout, MutAnyOrigin],
    point_count_device: Int32,
    query_count_device: Int32,
    dimension_device: Int32,
    metric: Int32,
):
    comptime assert vectors.flat_rank == 1
    comptime assert queries.flat_rank == 1
    comptime assert scores.flat_rank == 1
    var point_count = Int(point_count_device)
    var query_count = Int(query_count_device)
    var dimension = Int(dimension_device)
    var job = global_idx.x
    if job >= point_count * query_count:
        return
    var query_index = job // point_count
    var point_index = job % point_count
    var score: Scalar[DType.float32] = 0.0
    var query_norm: Scalar[DType.float32] = 0.0
    var point_norm: Scalar[DType.float32] = 0.0
    for column in range(dimension):
        var query_value = rebind[Scalar[DType.float32]](
            queries[query_index * dimension + column]
        )
        var point_value = rebind[Scalar[DType.float32]](
            vectors[point_index * dimension + column]
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
    ScoresLayout: TensorLayout,
    IdsLayout: TensorLayout,
    OutputIdsLayout: TensorLayout,
    OutputScoresLayout: TensorLayout,
](
    scores: TileTensor[DType.float32, ScoresLayout, MutAnyOrigin],
    ids: TileTensor[DType.int64, IdsLayout, MutAnyOrigin],
    output_ids: TileTensor[DType.int64, OutputIdsLayout, MutAnyOrigin],
    output_scores: TileTensor[DType.float32, OutputScoresLayout, MutAnyOrigin],
    point_count_device: Int32,
    query_count_device: Int32,
    result_count_device: Int32,
    metric: Int32,
):
    comptime assert scores.flat_rank == 1
    comptime assert ids.flat_rank == 1
    comptime assert output_ids.flat_rank == 1
    comptime assert output_scores.flat_rank == 1
    var point_count = Int(point_count_device)
    var query_count = Int(query_count_device)
    var result_count = Int(result_count_device)
    var query_index = global_idx.x
    if query_index >= query_count:
        return
    for rank in range(result_count):
        var best_point = -1
        var best_id: Scalar[DType.int64] = 0
        var best_score: Scalar[DType.float32] = 0.0
        for point_index in range(point_count):
            var candidate_id = rebind[Scalar[DType.int64]](ids[point_index])
            var already_selected = False
            for previous in range(rank):
                if (
                    rebind[Scalar[DType.int64]](
                        output_ids[query_index * result_count + previous]
                    )
                    == candidate_id
                ):
                    already_selected = True
                    break
            if already_selected:
                continue
            var candidate_score = rebind[Scalar[DType.float32]](
                scores[query_index * point_count + point_index]
            )
            var better = best_point < 0
            if best_point >= 0:
                if candidate_score == best_score:
                    better = candidate_id < best_id
                elif metric == Int32(BATCH_L2_METRIC):
                    better = candidate_score < best_score
                else:
                    better = candidate_score > best_score
            if better:
                best_point = point_index
                best_id = candidate_id
                best_score = candidate_score
        output_ids[query_index * result_count + rank] = rebind[
            output_ids.ElementType
        ](best_id)
        output_scores[query_index * result_count + rank] = rebind[
            output_scores.ElementType
        ](best_score)


def execute_device_batch[
    use_accelerator: Bool
](
    memtable: MemTable,
    queries: List[List[Float32]],
    k: Int,
    metric: Int,
    options: GpuExecutionOptions,
) raises -> DeviceBatchResult:
    """Run GPU batch search or return the exact CPU fallback with a reason."""
    comptime if not use_accelerator:
        var plan = plan_gpu_execution(
            False,
            len(queries),
            len(memtable.live_entries()),
            memtable.dimension,
            k,
            options,
        )
        return _cpu_fallback(memtable, queries, k, metric, plan)
    else:
        comptime if not has_accelerator():
            var plan = plan_gpu_execution(
                False,
                len(queries),
                len(memtable.live_entries()),
                memtable.dimension,
                k,
                options,
            )
            return _cpu_fallback(memtable, queries, k, metric, plan)
        else:
            var plan = plan_gpu_execution(
                True,
                len(queries),
                len(memtable.live_entries()),
                memtable.dimension,
                k,
                options,
            )
            if not plan.use_gpu:
                return _cpu_fallback(memtable, queries, k, metric, plan)
            try:
                if options.fail_before_launch:
                    raise Error("injected GPU launch failure")
                var results = _execute_gpu_batch(
                    memtable,
                    queries,
                    k,
                    metric,
                    options.block_size,
                    plan.required_bytes,
                )
                return DeviceBatchResult(
                    results^,
                    True,
                    "gpu executed",
                    plan.required_bytes,
                    _execution_stats(
                        metric,
                        "gpu executed",
                        True,
                        len(queries) * len(memtable.live_entries()),
                    ),
                )
            except error:
                var fallback_results = execute_exact_batch(
                    memtable, queries, k, metric, 0
                )
                return DeviceBatchResult(
                    fallback_results^,
                    False,
                    "gpu failure: " + String(error),
                    plan.required_bytes,
                    _execution_stats(
                        metric,
                        "gpu failure: " + String(error),
                        False,
                        len(queries) * len(memtable.live_entries()),
                    ),
                )


def execute_device_candidate_batch[
    use_accelerator: Bool
](
    dimension: Int,
    queries: List[List[Float32]],
    candidates: List[List[MemTableEntry]],
    k: Int,
    metric: Int,
    options: GpuExecutionOptions,
) raises -> DeviceBatchResult:
    """Execute one filtered candidate set per input query ordinal."""
    if len(queries) != len(candidates):
        raise Error("device query and candidate counts must match")
    var output = List[List[SearchResult]](capacity=len(queries))
    var every_query_used_gpu = len(queries) > 0
    var reason = String("gpu executed")
    var required_bytes = UInt64(0)
    var evaluations = 0
    var any_gpu = False
    var any_cpu = False
    for query_index in range(len(queries)):
        var table = MemTable(dimension)
        for candidate_index in range(len(candidates[query_index])):
            var values = candidates[query_index][candidate_index].values.copy()
            table.apply_upsert(
                candidates[query_index][candidate_index].id,
                UInt64(candidate_index + 1),
                values^,
            )
        var singleton = List[List[Float32]]()
        singleton.append(queries[query_index].copy())
        var result = execute_device_batch[use_accelerator](
            table, singleton, k, metric, options
        )
        if result.required_bytes > required_bytes:
            required_bytes = result.required_bytes
        evaluations += result.stats.distance_evaluations
        any_gpu = any_gpu or result.used_gpu
        any_cpu = any_cpu or not result.used_gpu
        if not result.used_gpu:
            every_query_used_gpu = False
            if reason == "gpu executed":
                reason = String(copy=result.reason)
        var query_results = result.take_results()
        output.append(query_results.pop())
    if len(queries) == 0:
        reason = "empty workload"
    var stats = _execution_stats(
        metric, reason, every_query_used_gpu, evaluations
    )
    if any_gpu and any_cpu:
        stats.backend_name = "mixed"
    return DeviceBatchResult(
        output^, every_query_used_gpu, reason, required_bytes, stats^
    )


def _cpu_fallback(
    memtable: MemTable,
    queries: List[List[Float32]],
    k: Int,
    metric: Int,
    plan: GpuPlan,
) raises -> DeviceBatchResult:
    var results = execute_exact_batch(memtable, queries, k, metric, 0)
    var evaluations = len(queries) * len(memtable.live_entries())
    return DeviceBatchResult(
        results^,
        False,
        plan.reason,
        plan.required_bytes,
        _execution_stats(metric, plan.reason, False, evaluations),
    )


def _execute_gpu_batch(
    memtable: MemTable,
    queries: List[List[Float32]],
    k: Int,
    metric: Int,
    block_size: Int,
    required_bytes: UInt64,
) raises -> List[List[SearchResult]]:
    _validate_gpu_inputs(memtable, queries, k, metric)
    var entries = memtable.live_entries()
    var point_count = len(entries)
    var query_count = len(queries)
    var result_count = min(k, point_count)
    if point_count > Int(Int32.MAX) or query_count > Int(Int32.MAX):
        raise Error("GPU query shape exceeds Int32 launch format")
    if memtable.dimension > Int(Int32.MAX):
        raise Error("GPU dimension exceeds Int32 launch format")
    var vector_count = point_count * memtable.dimension
    var query_value_count = query_count * memtable.dimension
    var score_count = query_count * point_count
    var output_count = query_count * result_count
    var context = DeviceContext()
    var memory = context.get_memory_info()
    if required_bytes > UInt64(memory[0]):
        raise Error("GPU free memory is below planned allocation")
    var vectors_buffer = context.enqueue_create_buffer[DType.float32](
        vector_count
    )
    var queries_buffer = context.enqueue_create_buffer[DType.float32](
        query_value_count
    )
    var scores_buffer = context.enqueue_create_buffer[DType.float32](
        score_count
    )
    var ids_buffer = context.enqueue_create_buffer[DType.int64](point_count)
    var output_ids_buffer = context.enqueue_create_buffer[DType.int64](
        output_count
    )
    var output_scores_buffer = context.enqueue_create_buffer[DType.float32](
        output_count
    )
    with vectors_buffer.map_to_host() as host:
        for point_index in range(point_count):
            for column in range(memtable.dimension):
                host[point_index * memtable.dimension + column] = entries[
                    point_index
                ].values[column]
    with queries_buffer.map_to_host() as host:
        for query_index in range(query_count):
            for column in range(memtable.dimension):
                host[query_index * memtable.dimension + column] = queries[
                    query_index
                ][column]
    with ids_buffer.map_to_host() as host:
        for point_index in range(point_count):
            host[point_index] = Int64(entries[point_index].id)

    var vectors_layout = row_major(vector_count)
    var queries_layout = row_major(query_value_count)
    var scores_layout = row_major(score_count)
    var ids_layout = row_major(point_count)
    var output_ids_layout = row_major(output_count)
    var output_scores_layout = row_major(output_count)
    var vectors_tensor = TileTensor(vectors_buffer, vectors_layout)
    var queries_tensor = TileTensor(queries_buffer, queries_layout)
    var scores_tensor = TileTensor(scores_buffer, scores_layout)
    var ids_tensor = TileTensor(ids_buffer, ids_layout)
    var output_ids_tensor = TileTensor(output_ids_buffer, output_ids_layout)
    var output_scores_tensor = TileTensor(
        output_scores_buffer, output_scores_layout
    )
    comptime score_kernel = _score_kernel[
        type_of(vectors_layout),
        type_of(queries_layout),
        type_of(scores_layout),
    ]
    context.enqueue_function[score_kernel](
        vectors_tensor,
        queries_tensor,
        scores_tensor,
        Int32(point_count),
        Int32(query_count),
        Int32(memtable.dimension),
        Int32(metric),
        grid_dim=ceildiv(score_count, block_size),
        block_dim=block_size,
    )
    comptime topk_kernel = _topk_kernel[
        type_of(scores_layout),
        type_of(ids_layout),
        type_of(output_ids_layout),
        type_of(output_scores_layout),
    ]
    context.enqueue_function[topk_kernel](
        scores_tensor,
        ids_tensor,
        output_ids_tensor,
        output_scores_tensor,
        Int32(point_count),
        Int32(query_count),
        Int32(result_count),
        Int32(metric),
        grid_dim=ceildiv(query_count, block_size),
        block_dim=block_size,
    )
    context.synchronize()

    var output = List[List[SearchResult]](capacity=query_count)
    with output_ids_buffer.map_to_host() as host_ids:
        with output_scores_buffer.map_to_host() as host_scores:
            for query_index in range(query_count):
                var query_results = List[SearchResult](capacity=result_count)
                for rank in range(result_count):
                    var offset = query_index * result_count + rank
                    query_results.append(
                        SearchResult(
                            Int(host_ids[offset]), Float32(host_scores[offset])
                        )
                    )
                output.append(query_results^)
    return output^


def _validate_gpu_inputs(
    memtable: MemTable,
    queries: List[List[Float32]],
    k: Int,
    metric: Int,
) raises:
    if k <= 0:
        raise Error("k must be positive")
    if (
        metric != BATCH_DOT_METRIC
        and metric != BATCH_L2_METRIC
        and metric != BATCH_COSINE_METRIC
    ):
        raise Error("unknown GPU query metric")
    var entries = memtable.live_entries()
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
    if metric == BATCH_COSINE_METRIC:
        for entry_index in range(len(entries)):
            var norm: Float32 = 0.0
            for value in entries[entry_index].values:
                norm += value * value
            if norm == 0.0:
                raise Error("cosine similarity requires non-zero vectors")
