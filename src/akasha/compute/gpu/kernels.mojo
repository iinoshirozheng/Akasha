from akasha.compute.gpu.planner import GPU_TILE_POINTS
from layout import TileTensor, TensorLayout, row_major, stack_allocation
from max.gpu.memory import AddressSpace
from max.gpu.sync import barrier
from std.gpu import block_dim, block_idx, thread_idx, WARP_SIZE, lane_id
from std.gpu.primitives import warp
from std.math import isnan


@always_inline
def _better[
    metric: Int
](lhs: Float32, lhs_id: Int64, rhs: Float32, rhs_id: Int64) -> Bool:
    # A total order also keeps reductions safe if arithmetic overflows to NaN.
    if isnan(lhs):
        return isnan(rhs) and lhs_id < rhs_id
    if isnan(rhs):
        return True
    if lhs == rhs:
        return lhs_id < rhs_id
    comptime if metric == 1:
        return lhs < rhs
    else:
        return lhs > rhs


def distance_partial_topk[
    metric: Int, L: TensorLayout
](
    vectors: TileTensor[DType.float32, L, MutAnyOrigin],
    queries: TileTensor[DType.float32, L, MutAnyOrigin],
    ids: TileTensor[DType.int64, L, MutAnyOrigin],
    candidates: TileTensor[DType.int64, L, MutAnyOrigin],
    offsets: TileTensor[DType.int64, L, MutAnyOrigin],
    tile_offsets: TileTensor[DType.int64, L, MutAnyOrigin],
    partial_ids: TileTensor[DType.int64, L, MutAnyOrigin],
    partial_scores: TileTensor[DType.float32, L, MutAnyOrigin],
    point_count: Int32,
    query_count: Int32,
    dimension: Int32,
    partial_stride: Int32,
    filtered: Int32,
):
    comptime assert (
        vectors.flat_rank == 1 and queries.flat_rank == 1 and ids.flat_rank == 1
    )
    comptime assert (
        candidates.flat_rank == 1
        and offsets.flat_rank == 1
        and tile_offsets.flat_rank == 1
    )
    comptime assert partial_ids.flat_rank == 1 and partial_scores.flat_rank == 1
    var tid = thread_idx.x
    var tile = block_idx.x
    var left = 0
    var right = Int(query_count)
    while left < right:
        var mid = (left + right) // 2
        if Int(rebind[Int64](tile_offsets[mid + 1])) <= tile:
            left = mid + 1
        else:
            right = mid
    var query = left
    var query_start = Int(rebind[Int64](offsets[query]))
    var start = (
        query_start
        + (tile - Int(rebind[Int64](tile_offsets[query]))) * GPU_TILE_POINTS
    )
    var count = min(
        GPU_TILE_POINTS, Int(rebind[Int64](offsets[query + 1])) - start
    )
    var scores = stack_allocation[
        DType.float32, address_space=AddressSpace.SHARED
    ](row_major[GPU_TILE_POINTS]())
    var keys = stack_allocation[DType.int64, address_space=AddressSpace.SHARED](
        row_major[GPU_TILE_POINTS]()
    )
    var live = stack_allocation[DType.int32, address_space=AddressSpace.SHARED](
        row_major[GPU_TILE_POINTS]()
    )
    var best = stack_allocation[DType.int32, address_space=AddressSpace.SHARED](
        row_major[1024]()
    )
    comptime assert (
        scores.flat_rank == 1
        and keys.flat_rank == 1
        and live.flat_rank == 1
        and best.flat_rank == 1
    )
    if block_dim.x >= WARP_SIZE and block_dim.x % WARP_SIZE == 0:
        var lane = lane_id()
        for point in range(tid // WARP_SIZE, count, block_dim.x // WARP_SIZE):
            var position = (
                Int(rebind[Int64](candidates[start + point])) if filtered
                != 0 else start + point - query_start
            )
            var score: Float32 = 0.0
            for column in range(lane, Int(dimension), WARP_SIZE):
                var lhs = rebind[Float32](
                    queries[query * Int(dimension) + column]
                )
                var rhs = rebind[Float32](
                    vectors[position * Int(dimension) + column]
                )
                comptime if metric == 1:
                    var delta = lhs - rhs
                    score += delta * delta
                else:
                    score += lhs * rhs
            score = warp.sum(score)
            if lane == 0:
                comptime if metric == 2:
                    score /= rebind[Float32](
                        queries[Int(query_count) * Int(dimension) + query]
                    ) * rebind[Float32](
                        vectors[Int(point_count) * Int(dimension) + position]
                    )
                scores[point] = score
                keys[point] = rebind[Int64](ids[position])
    else:
        # Honor arbitrary public block sizes, including partial warps.
        for point in range(tid, count, block_dim.x):
            var position = (
                Int(rebind[Int64](candidates[start + point])) if filtered
                != 0 else start + point - query_start
            )
            var score: Float32 = 0.0
            for column in range(Int(dimension)):
                var lhs = rebind[Float32](
                    queries[query * Int(dimension) + column]
                )
                var rhs = rebind[Float32](
                    vectors[position * Int(dimension) + column]
                )
                comptime if metric == 1:
                    var delta = lhs - rhs
                    score += delta * delta
                else:
                    score += lhs * rhs
            comptime if metric == 2:
                score /= rebind[Float32](
                    queries[Int(query_count) * Int(dimension) + query]
                ) * rebind[Float32](
                    vectors[Int(point_count) * Int(dimension) + position]
                )
            scores[point] = score
            keys[point] = rebind[Int64](ids[position])
    for point in range(tid, count, block_dim.x):
        live[point] = 1
    barrier()
    for rank in range(min(Int(partial_stride), count)):
        var local = -1
        for point in range(tid, count, block_dim.x):
            if rebind[Int32](live[point]) == 0:
                continue
            if local < 0 or _better[metric](
                rebind[Float32](scores[point]),
                rebind[Int64](keys[point]),
                rebind[Float32](scores[local]),
                rebind[Int64](keys[local]),
            ):
                local = point
        best[tid] = Int32(local)
        barrier()
        var active = block_dim.x
        while active > 1:
            var next_active = (active + 1) // 2
            if tid + next_active < active:
                var lhs = Int(rebind[Int32](best[tid]))
                var rhs = Int(rebind[Int32](best[tid + next_active]))
                if rhs >= 0 and (
                    lhs < 0
                    or _better[metric](
                        rebind[Float32](scores[rhs]),
                        rebind[Int64](keys[rhs]),
                        rebind[Float32](scores[lhs]),
                        rebind[Int64](keys[lhs]),
                    )
                ):
                    best[tid] = Int32(rhs)
            barrier()
            active = next_active
        if tid == 0:
            var winner = Int(rebind[Int32](best[0]))
            var output = tile * Int(partial_stride) + rank
            partial_ids[output] = rebind[partial_ids.ElementType](keys[winner])
            partial_scores[output] = rebind[partial_scores.ElementType](
                scores[winner]
            )
            live[winner] = 0
        barrier()


def merge_partial_topk[
    metric: Int, L: TensorLayout
](
    partial_ids: TileTensor[DType.int64, L, MutAnyOrigin],
    partial_scores: TileTensor[DType.float32, L, MutAnyOrigin],
    offsets: TileTensor[DType.int64, L, MutAnyOrigin],
    tile_offsets: TileTensor[DType.int64, L, MutAnyOrigin],
    output_ids: TileTensor[DType.int64, L, MutAnyOrigin],
    output_scores: TileTensor[DType.float32, L, MutAnyOrigin],
    result_stride: Int32,
    partial_stride: Int32,
):
    comptime assert partial_ids.flat_rank == 1 and partial_scores.flat_rank == 1
    comptime assert offsets.flat_rank == 1 and tile_offsets.flat_rank == 1
    comptime assert output_ids.flat_rank == 1 and output_scores.flat_rank == 1
    var query = block_idx.x
    var tid = thread_idx.x
    var count = Int(
        rebind[Int64](offsets[query + 1]) - rebind[Int64](offsets[query])
    )
    var first_tile = Int(rebind[Int64](tile_offsets[query]))
    var tiles = Int(rebind[Int64](tile_offsets[query + 1])) - first_tile
    var scores = stack_allocation[
        DType.float32, address_space=AddressSpace.SHARED
    ](row_major[1024]())
    var keys = stack_allocation[DType.int64, address_space=AddressSpace.SHARED](
        row_major[1024]()
    )
    var best = stack_allocation[DType.int32, address_space=AddressSpace.SHARED](
        row_major[1024]()
    )
    comptime assert (
        scores.flat_rank == 1 and keys.flat_rank == 1 and best.flat_rank == 1
    )
    var previous_score: Float32 = 0.0
    var previous_id: Int64 = 0
    for rank in range(min(Int(result_stride), count)):
        var local = -1
        var local_score: Float32 = 0.0
        var local_id: Int64 = 0
        for candidate in range(tid, tiles * Int(partial_stride), block_dim.x):
            var tile = candidate // Int(partial_stride)
            if candidate % Int(partial_stride) >= min(
                Int(partial_stride), count - tile * GPU_TILE_POINTS
            ):
                continue
            var index = first_tile * Int(partial_stride) + candidate
            var score = rebind[Float32](partial_scores[index])
            var id = rebind[Int64](partial_ids[index])
            if rank > 0 and not _better[metric](
                previous_score, previous_id, score, id
            ):
                continue
            if local < 0 or _better[metric](score, id, local_score, local_id):
                local = candidate
                local_score = score
                local_id = id
        scores[tid] = local_score
        keys[tid] = local_id
        best[tid] = Int32(tid if local >= 0 else -1)
        barrier()
        var active = block_dim.x
        while active > 1:
            var next_active = (active + 1) // 2
            if tid + next_active < active:
                var lhs = Int(rebind[Int32](best[tid]))
                var rhs = Int(rebind[Int32](best[tid + next_active]))
                if rhs >= 0 and (
                    lhs < 0
                    or _better[metric](
                        rebind[Float32](scores[rhs]),
                        rebind[Int64](keys[rhs]),
                        rebind[Float32](scores[lhs]),
                        rebind[Int64](keys[lhs]),
                    )
                ):
                    best[tid] = Int32(rhs)
            barrier()
            active = next_active
        var winner = Int(rebind[Int32](best[0]))
        previous_score = rebind[Float32](scores[winner])
        previous_id = rebind[Int64](keys[winner])
        if tid == 0:
            output_ids[query * Int(result_stride) + rank] = rebind[
                output_ids.ElementType
            ](previous_id)
            output_scores[query * Int(result_stride) + rank] = rebind[
                output_scores.ElementType
            ](previous_score)
        barrier()
