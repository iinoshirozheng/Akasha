from akasha.compute.simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
from akasha.compute.topk import BoundedTopK


comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct SearchResult(TrivialRegisterPassable, Writable):
    """A point ID and its raw metric score."""

    var id: Int
    var score: Float32

    def __init__(out self, id: Int, score: Float32):
        self.id = id
        self.score = score


struct _VectorRecord(Movable):
    var id: Int
    var values: List[Float32]

    def __init__(out self, id: Int, var values: List[Float32]):
        self.id = id
        self.values = values^


def authoritative_f32_score(
    metric: Int, query: List[Float32], candidate: List[Float32]
) raises -> Float32:
    """Use the exact-search F32 arithmetic for authoritative public scores."""
    if metric == _DOT_METRIC:
        return simd_dot_product(query, candidate)
    if metric == _L2_METRIC:
        return simd_l2_squared_distance(query, candidate)
    return simd_cosine_similarity(query, candidate)


struct FlatIndex:
    """An owning in-memory index that performs deterministic exact search."""

    var dimension: Int
    var _records: List[_VectorRecord]

    def __init__(out self, dimension: Int) raises:
        if dimension <= 0:
            raise Error("index dimension must be positive")
        self.dimension = dimension
        self._records = List[_VectorRecord]()

    def add(mut self, id: Int, var values: List[Float32]) raises:
        """Add an owned point vector to the index."""
        if len(values) != self.dimension:
            raise Error("vector dimension does not match index")
        self._records.append(_VectorRecord(id, values^))

    def search_dot(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        """Return the highest raw dot-product scores first."""
        return self._search(query, k, _DOT_METRIC)

    def search_l2(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        """Return the smallest squared L2 distances first."""
        return self._search(query, k, _L2_METRIC)

    def search_cosine(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        """Return the highest cosine similarities first."""
        return self._search(query, k, _COSINE_METRIC)

    def _search(
        self, query: List[Float32], k: Int, metric: Int
    ) raises -> List[SearchResult]:
        if len(query) != self.dimension:
            raise Error("query dimension does not match index")
        if k <= 0:
            raise Error("k must be positive")

        var result_count = k
        if result_count > len(self._records):
            result_count = len(self._records)

        if result_count == 0:
            return List[SearchResult]()

        var topk = BoundedTopK(
            result_count, smaller_is_better=metric == _L2_METRIC
        )
        for record_index in range(len(self._records)):
            topk.offer(
                self._records[record_index].id,
                authoritative_f32_score(
                    metric, query, self._records[record_index].values
                ),
            )

        var entries = topk.sorted_entries()
        var results = List[SearchResult](capacity=len(entries))
        for entry in entries:
            results.append(SearchResult(entry.id, entry.score))

        return results^
