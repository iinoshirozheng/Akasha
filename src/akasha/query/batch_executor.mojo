from akasha.compute.simd import (
    prevalidated_simd_cosine_similarity,
    prevalidated_simd_dot_product,
    prevalidated_simd_l2_squared_distance,
)
from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult
from akasha.storage.memtable import MemTable, MemTableEntry
from max.algorithm import parallelize
from std.math import isfinite


comptime BATCH_DOT_METRIC = 0
comptime BATCH_L2_METRIC = 1
comptime BATCH_COSINE_METRIC = 2


def execute_exact_batch(
    memtable: MemTable,
    queries: List[List[Float32]],
    k: Int,
    metric: Int,
    num_workers: Int,
) raises -> List[List[SearchResult]]:
    """Execute validated queries with one deterministic heap per input."""
    if k <= 0:
        raise Error("k must be positive")
    if num_workers < 0:
        raise Error("batch query worker count cannot be negative")
    if (
        metric != BATCH_DOT_METRIC
        and metric != BATCH_L2_METRIC
        and metric != BATCH_COSINE_METRIC
    ):
        raise Error("unknown batch query metric")
    for query_index in range(len(queries)):
        if len(queries[query_index]) != memtable.dimension:
            raise Error("query dimension does not match snapshot")
        var query_norm: Float32 = 0.0
        for value in queries[query_index]:
            if not isfinite(value):
                raise Error("query vector must contain only finite values")
            query_norm += value * value
        if metric == BATCH_COSINE_METRIC and query_norm == 0.0:
            raise Error("cosine similarity requires non-zero vectors")
    if len(queries) == 0:
        return List[List[SearchResult]]()

    var entries = memtable.live_entries()
    if metric == BATCH_COSINE_METRIC:
        for entry_index in range(len(entries)):
            var candidate_norm: Float32 = 0.0
            for value in entries[entry_index].values:
                candidate_norm += value * value
            if candidate_norm == 0.0:
                raise Error("cosine similarity requires non-zero vectors")

    var result_count = min(k, len(entries))
    var output = List[List[SearchResult]](capacity=len(queries))
    if result_count == 0:
        for _ in range(len(queries)):
            output.append(List[SearchResult]())
        return output^

    var heaps = List[BoundedTopK](capacity=len(queries))
    for _ in range(len(queries)):
        heaps.append(
            BoundedTopK(
                result_count,
                smaller_is_better=metric == BATCH_L2_METRIC,
            )
        )

    def score_query(
        query_index: Int,
    ) {imm queries, imm entries, mut heaps, imm metric}:
        for entry_index in range(len(entries)):
            var score: Float32
            if metric == BATCH_DOT_METRIC:
                score = prevalidated_simd_dot_product(
                    queries[query_index], entries[entry_index].values
                )
            elif metric == BATCH_L2_METRIC:
                score = prevalidated_simd_l2_squared_distance(
                    queries[query_index], entries[entry_index].values
                )
            else:
                score = prevalidated_simd_cosine_similarity(
                    queries[query_index], entries[entry_index].values
                )
            heaps[query_index].offer(entries[entry_index].id, score)

    if len(queries) < 4 or num_workers == 1:
        for query_index in range(len(queries)):
            score_query(query_index)
    elif num_workers == 0:
        parallelize(score_query, len(queries))
    else:
        parallelize(score_query, len(queries), min(num_workers, len(queries)))

    for query_index in range(len(queries)):
        var retained = heaps[query_index].sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        output.append(results^)
    return output^


def execute_exact_candidate_batch(
    dimension: Int,
    queries: List[List[Float32]],
    candidates: List[List[MemTableEntry]],
    k: Int,
    metric: Int,
    num_workers: Int,
) raises -> List[List[SearchResult]]:
    """Score one pre-materialized candidate set per query ordinal."""
    if len(queries) != len(candidates):
        raise Error("batch query candidate count mismatch")
    if k <= 0:
        raise Error("k must be positive")
    if num_workers < 0:
        raise Error("batch query worker count cannot be negative")
    if (
        metric != BATCH_DOT_METRIC
        and metric != BATCH_L2_METRIC
        and metric != BATCH_COSINE_METRIC
    ):
        raise Error("unknown batch query metric")
    for query_index in range(len(queries)):
        if len(queries[query_index]) != dimension:
            raise Error("query dimension does not match snapshot")
        var query_norm: Float32 = 0.0
        for value in queries[query_index]:
            if not isfinite(value):
                raise Error("query vector must contain only finite values")
            query_norm += value * value
        if metric == BATCH_COSINE_METRIC and query_norm == 0.0:
            raise Error("cosine similarity requires non-zero vectors")
        if metric == BATCH_COSINE_METRIC:
            for entry_index in range(len(candidates[query_index])):
                var candidate_norm: Float32 = 0.0
                for value in candidates[query_index][entry_index].values:
                    candidate_norm += value * value
                if candidate_norm == 0.0:
                    raise Error("cosine similarity requires non-zero vectors")
    if len(queries) == 0:
        return List[List[SearchResult]]()

    var heaps = List[BoundedTopK](capacity=len(queries))
    for _ in range(len(queries)):
        heaps.append(
            BoundedTopK(
                k,
                smaller_is_better=metric == BATCH_L2_METRIC,
            )
        )

    def score_query(
        query_index: Int,
    ) {imm queries, imm candidates, mut heaps, imm metric}:
        for entry_index in range(len(candidates[query_index])):
            var score = _score_prevalidated(
                metric,
                queries[query_index],
                candidates[query_index][entry_index].values,
            )
            heaps[query_index].offer(
                candidates[query_index][entry_index].id, score
            )

    if len(queries) < 4 or num_workers == 1:
        for query_index in range(len(queries)):
            score_query(query_index)
    elif num_workers == 0:
        parallelize(score_query, len(queries))
    else:
        parallelize(score_query, len(queries), min(num_workers, len(queries)))

    var output = List[List[SearchResult]](capacity=len(queries))
    for query_index in range(len(queries)):
        var retained = heaps[query_index].sorted_entries()
        var results = List[SearchResult](capacity=len(retained))
        for entry in retained:
            results.append(SearchResult(entry.id, entry.score))
        output.append(results^)
    return output^


def _score_prevalidated(
    metric: Int, lhs: List[Float32], rhs: List[Float32]
) -> Float32:
    if metric == BATCH_DOT_METRIC:
        return prevalidated_simd_dot_product(lhs, rhs)
    if metric == BATCH_L2_METRIC:
        return prevalidated_simd_l2_squared_distance(lhs, rhs)
    return prevalidated_simd_cosine_similarity(lhs, rhs)
