from akasha.compute.distance import (
    cosine_similarity,
    dot_product,
    l2_squared_distance,
)


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


def _score(
    metric: Int, query: List[Float32], candidate: List[Float32]
) raises -> Float32:
    if metric == _DOT_METRIC:
        return dot_product(query, candidate)
    if metric == _L2_METRIC:
        return l2_squared_distance(query, candidate)
    return cosine_similarity(query, candidate)


def _is_better(
    metric: Int,
    score: Float32,
    point_id: Int,
    best_score: Float32,
    best_id: Int,
) -> Bool:
    if score == best_score:
        return point_id < best_id
    if metric == _L2_METRIC:
        return score < best_score
    return score > best_score


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

        var selected = List[Bool]()
        for _ in range(len(self._records)):
            selected.append(False)

        var results = List[SearchResult]()
        for _ in range(result_count):
            var best_index = -1
            var best_id = 0
            var best_score: Float32 = 0.0

            for record_index in range(len(self._records)):
                if selected[record_index]:
                    continue

                var candidate_score = _score(
                    metric, query, self._records[record_index].values
                )
                var candidate_id = self._records[record_index].id
                if best_index == -1 or _is_better(
                    metric,
                    candidate_score,
                    candidate_id,
                    best_score,
                    best_id,
                ):
                    best_index = record_index
                    best_id = candidate_id
                    best_score = candidate_score

            selected[best_index] = True
            results.append(SearchResult(best_id, best_score))

        return results^
