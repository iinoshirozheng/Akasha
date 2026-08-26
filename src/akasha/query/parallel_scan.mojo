from akasha.compute.simd import (
    prevalidated_simd_cosine_similarity,
    prevalidated_simd_dot_product,
    prevalidated_simd_l2_squared_distance,
)
from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult
from akasha.query.batch_executor import (
    BATCH_COSINE_METRIC,
    BATCH_DOT_METRIC,
    BATCH_L2_METRIC,
)
from akasha.storage.memtable import MemTableEntry
from max.algorithm import parallelize
from std.math import isfinite


def execute_parallel_scan(
    dimension: Int,
    entries: List[MemTableEntry],
    query: List[Float32],
    k: Int,
    metric: Int,
    num_workers: Int,
) raises -> List[SearchResult]:
    """Scan deterministic ordinal ranges and merge range-local Top-K heaps."""
    if dimension <= 0 or len(query) != dimension:
        raise Error("query dimension does not match snapshot")
    if k <= 0:
        raise Error("k must be positive")
    if num_workers < 0:
        raise Error("parallel scan worker count cannot be negative")
    if (
        metric != BATCH_DOT_METRIC
        and metric != BATCH_L2_METRIC
        and metric != BATCH_COSINE_METRIC
    ):
        raise Error("unknown parallel scan metric")
    var query_norm: Float32 = 0.0
    for value in query:
        if not isfinite(value):
            raise Error("query vector must contain only finite values")
        query_norm += value * value
    if metric == BATCH_COSINE_METRIC and query_norm == 0.0:
        raise Error("cosine similarity requires non-zero vectors")
    for entry_index in range(len(entries)):
        if len(entries[entry_index].values) != dimension:
            raise Error("parallel scan candidate dimension mismatch")
        if metric == BATCH_COSINE_METRIC:
            var candidate_norm: Float32 = 0.0
            for value in entries[entry_index].values:
                candidate_norm += value * value
            if candidate_norm == 0.0:
                raise Error("cosine similarity requires non-zero vectors")
    if len(entries) == 0:
        return List[SearchResult]()

    var result_count = min(k, len(entries))
    var range_count = 8 if num_workers == 0 else num_workers
    range_count = min(max(range_count, 1), len(entries))
    var heaps = List[BoundedTopK](capacity=range_count)
    for _ in range(range_count):
        heaps.append(
            BoundedTopK(
                result_count,
                smaller_is_better=metric == BATCH_L2_METRIC,
            )
        )

    def scan_range(
        range_index: Int,
    ) {imm entries, imm query, imm metric, imm range_count, mut heaps}:
        var start = (len(entries) * range_index) // range_count
        var end = (len(entries) * (range_index + 1)) // range_count
        for entry_index in range(start, end):
            var score: Float32
            if metric == BATCH_DOT_METRIC:
                score = prevalidated_simd_dot_product(
                    query, entries[entry_index].values
                )
            elif metric == BATCH_L2_METRIC:
                score = prevalidated_simd_l2_squared_distance(
                    query, entries[entry_index].values
                )
            else:
                score = prevalidated_simd_cosine_similarity(
                    query, entries[entry_index].values
                )
            heaps[range_index].offer(entries[entry_index].id, score)

    if range_count == 1:
        scan_range(0)
    elif num_workers == 0:
        parallelize(scan_range, range_count)
    else:
        parallelize(scan_range, range_count, min(num_workers, range_count))

    var merged = BoundedTopK(
        result_count, smaller_is_better=metric == BATCH_L2_METRIC
    )
    for range_index in range(range_count):
        var local = heaps[range_index].sorted_entries()
        for entry in local:
            merged.offer(entry.id, entry.score)
    var retained = merged.sorted_entries()
    var output = List[SearchResult](capacity=len(retained))
    for entry in retained:
        output.append(SearchResult(entry.id, entry.score))
    return output^
