from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult
from std.math import isfinite, sqrt


comptime _SQ8_VERSION = UInt32(1)
comptime _PQ_VERSION = UInt32(1)
comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct Sq8Codebook(Movable):
    """Per-dimension affine scalar-quantization parameters."""

    var _dimension: Int
    var _minimums: List[Float32]
    var _scales: List[Float32]

    def __init__(
        out self,
        dimension: Int,
        var minimums: List[Float32],
        var scales: List[Float32],
    ) raises:
        if dimension <= 0:
            raise Error("SQ8 dimension must be positive")
        if len(minimums) != dimension or len(scales) != dimension:
            raise Error("SQ8 codebook column count mismatch")
        for index in range(dimension):
            if not isfinite(minimums[index]) or not isfinite(scales[index]):
                raise Error("SQ8 codebook values must be finite")
            if scales[index] < 0.0:
                raise Error("SQ8 scales cannot be negative")
        self._dimension = dimension
        self._minimums = minimums^
        self._scales = scales^

    @staticmethod
    def train(vectors: List[List[Float32]]) raises -> Sq8Codebook:
        if len(vectors) == 0 or len(vectors[0]) == 0:
            raise Error("SQ8 training requires non-empty vectors")
        var dimension = len(vectors[0])
        var minimums = List[Float32](length=dimension, fill=Float32(0.0))
        var maximums = List[Float32](length=dimension, fill=Float32(0.0))
        for row in range(len(vectors)):
            if len(vectors[row]) != dimension:
                raise Error("SQ8 training vectors must share one dimension")
            for column in range(dimension):
                var value = vectors[row][column]
                if not isfinite(value):
                    raise Error("SQ8 training vectors must be finite")
                if row == 0 or value < minimums[column]:
                    minimums[column] = value
                if row == 0 or value > maximums[column]:
                    maximums[column] = value
        var scales = List[Float32](length=dimension, fill=Float32(0.0))
        for column in range(dimension):
            var span = maximums[column] - minimums[column]
            if span > 0.0:
                scales[column] = span / 255.0
        return Sq8Codebook(dimension, minimums^, scales^)

    def version(self) -> UInt32:
        return _SQ8_VERSION

    def dimension(self) -> Int:
        return self._dimension

    def minimum(self, column: Int) raises -> Float32:
        self._validate_column(column)
        return self._minimums[column]

    def scale(self, column: Int) raises -> Float32:
        self._validate_column(column)
        return self._scales[column]

    def encode(self, vector: List[Float32]) raises -> List[UInt8]:
        if len(vector) != self._dimension:
            raise Error("vector dimension does not match SQ8 codebook")
        var codes = List[UInt8](capacity=self._dimension)
        for column in range(self._dimension):
            var value = vector[column]
            if not isfinite(value):
                raise Error("SQ8 vectors must be finite")
            if self._scales[column] == 0.0:
                codes.append(UInt8(0))
                continue
            var quantized = Int(
                (value - self._minimums[column]) / self._scales[column] + 0.5
            )
            if quantized < 0:
                quantized = 0
            elif quantized > 255:
                quantized = 255
            codes.append(UInt8(quantized))
        return codes^

    def decode(self, codes: List[UInt8]) raises -> List[Float32]:
        if len(codes) != self._dimension:
            raise Error("SQ8 code dimension mismatch")
        var vector = List[Float32](capacity=self._dimension)
        for column in range(self._dimension):
            vector.append(self.decode_value(column, codes[column]))
        return vector^

    def decode_value(self, column: Int, code: UInt8) raises -> Float32:
        self._validate_column(column)
        return self._minimums[column] + Float32(code) * self._scales[column]

    def _validate_column(self, column: Int) raises:
        if column < 0 or column >= self._dimension:
            raise Error("SQ8 column out of bounds")


struct Sq8Index(Movable):
    """Immutable scalar-quantized dense index with deterministic Top-K."""

    var _codebook: Sq8Codebook
    var _ids: List[Int]
    var _codes: List[UInt8]

    def __init__(
        out self,
        var codebook: Sq8Codebook,
        var ids: List[Int],
        var codes: List[UInt8],
    ) raises:
        if len(codes) != len(ids) * codebook.dimension():
            raise Error("SQ8 code payload length mismatch")
        self._codebook = codebook^
        self._ids = ids^
        self._codes = codes^

    @staticmethod
    def build(ids: List[Int], vectors: List[List[Float32]]) raises -> Sq8Index:
        if len(ids) != len(vectors):
            raise Error("SQ8 IDs and vectors must have equal lengths")
        var codebook = Sq8Codebook.train(vectors)
        var owned_ids = List[Int](capacity=len(ids))
        var codes = List[UInt8](capacity=len(ids) * codebook.dimension())
        for row in range(len(ids)):
            for previous in range(row):
                if ids[previous] == ids[row]:
                    raise Error("SQ8 point IDs must be unique")
            owned_ids.append(ids[row])
            var encoded = codebook.encode(vectors[row])
            for code in encoded:
                codes.append(code)
        return Sq8Index(codebook^, owned_ids^, codes^)

    def point_count(self) -> Int:
        return len(self._ids)

    def dimension(self) -> Int:
        return self._codebook.dimension()

    def encoded_bytes(self) -> Int:
        return len(self._codes)

    def search_dot(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, _DOT_METRIC)

    def search_l2(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, _L2_METRIC)

    def search_cosine(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, _COSINE_METRIC)

    def _search(
        self, query: List[Float32], k: Int, metric: Int
    ) raises -> List[SearchResult]:
        self._validate_query(query, k, metric)
        var result_count = min(k, len(self._ids))
        if result_count == 0:
            return List[SearchResult]()
        var topk = BoundedTopK(
            result_count, smaller_is_better=metric == _L2_METRIC
        )
        for row in range(len(self._ids)):
            topk.offer(self._ids[row], self._score(query, row, metric))
        var retained = topk.sorted_entries()
        var output = List[SearchResult](capacity=len(retained))
        for entry in retained:
            output.append(SearchResult(entry.id, entry.score))
        return output^

    def _score(
        self, query: List[Float32], row: Int, metric: Int
    ) raises -> Float32:
        var score: Float32 = 0.0
        var query_norm: Float32 = 0.0
        var candidate_norm: Float32 = 0.0
        for column in range(self.dimension()):
            var candidate = self._codebook.decode_value(
                column, self._codes[row * self.dimension() + column]
            )
            if metric == _L2_METRIC:
                var delta = query[column] - candidate
                score += delta * delta
            else:
                score += query[column] * candidate
                if metric == _COSINE_METRIC:
                    query_norm += query[column] * query[column]
                    candidate_norm += candidate * candidate
        if metric == _COSINE_METRIC:
            if candidate_norm == 0.0:
                raise Error("cosine similarity requires non-zero vectors")
            return score / (sqrt(query_norm) * sqrt(candidate_norm))
        return score

    def _validate_query(
        self, query: List[Float32], k: Int, metric: Int
    ) raises:
        if len(query) != self.dimension():
            raise Error("query dimension does not match SQ8 index")
        if k <= 0:
            raise Error("k must be positive")
        var norm: Float32 = 0.0
        for value in query:
            if not isfinite(value):
                raise Error("query vector must be finite")
            norm += value * value
        if metric == _COSINE_METRIC and norm == 0.0:
            raise Error("cosine similarity requires non-zero vectors")


struct PqCodebook(Movable):
    """Deterministically trained product-quantization centroids."""

    var _dimension: Int
    var _subquantizers: Int
    var _centroids: Int
    var _subdimension: Int
    var _values: List[Float32]

    def __init__(
        out self,
        dimension: Int,
        subquantizers: Int,
        centroids: Int,
        var values: List[Float32],
    ) raises:
        if dimension <= 0 or subquantizers <= 0:
            raise Error("PQ dimensions must be positive")
        if dimension % subquantizers != 0:
            raise Error("PQ dimension must divide into subquantizers")
        if centroids <= 0 or centroids > 256:
            raise Error("PQ centroid count must be between 1 and 256")
        var expected = dimension * centroids
        if len(values) != expected:
            raise Error("PQ centroid payload length mismatch")
        for value in values:
            if not isfinite(value):
                raise Error("PQ centroids must be finite")
        self._dimension = dimension
        self._subquantizers = subquantizers
        self._centroids = centroids
        self._subdimension = dimension // subquantizers
        self._values = values^

    @staticmethod
    def train(
        vectors: List[List[Float32]],
        subquantizers: Int,
        centroids: Int,
        *,
        iterations: Int = 8,
    ) raises -> PqCodebook:
        if len(vectors) == 0 or len(vectors[0]) == 0:
            raise Error("PQ training requires non-empty vectors")
        var dimension = len(vectors[0])
        if subquantizers <= 0 or dimension % subquantizers != 0:
            raise Error("PQ dimension must divide into subquantizers")
        if centroids <= 0 or centroids > 256 or centroids > len(vectors):
            raise Error("PQ centroid count exceeds supported training rows")
        if iterations <= 0:
            raise Error("PQ training iterations must be positive")
        for row in range(len(vectors)):
            if len(vectors[row]) != dimension:
                raise Error("PQ training vectors must share one dimension")
            for value in vectors[row]:
                if not isfinite(value):
                    raise Error("PQ training vectors must be finite")

        var subdimension = dimension // subquantizers
        var values = List[Float32](
            length=dimension * centroids, fill=Float32(0.0)
        )
        for subquantizer in range(subquantizers):
            for centroid in range(centroids):
                var source = (centroid * len(vectors)) // centroids
                for offset in range(subdimension):
                    values[
                        _pq_offset(
                            subquantizer,
                            centroid,
                            offset,
                            centroids,
                            subdimension,
                        )
                    ] = vectors[source][subquantizer * subdimension + offset]

        for _ in range(iterations):
            var sums = List[Float32](
                length=len(values), fill=Float32(0.0)
            )
            var counts = List[Int](
                length=subquantizers * centroids, fill=0
            )
            for row in range(len(vectors)):
                for subquantizer in range(subquantizers):
                    var nearest = _nearest_pq_centroid(
                        vectors[row],
                        subquantizer,
                        centroids,
                        subdimension,
                        values,
                    )
                    counts[subquantizer * centroids + nearest] += 1
                    for offset in range(subdimension):
                        sums[
                            _pq_offset(
                                subquantizer,
                                nearest,
                                offset,
                                centroids,
                                subdimension,
                            )
                        ] += vectors[row][
                            subquantizer * subdimension + offset
                        ]
            for subquantizer in range(subquantizers):
                for centroid in range(centroids):
                    var count = counts[subquantizer * centroids + centroid]
                    if count == 0:
                        continue
                    for offset in range(subdimension):
                        var index = _pq_offset(
                            subquantizer,
                            centroid,
                            offset,
                            centroids,
                            subdimension,
                        )
                        values[index] = sums[index] / Float32(count)
        return PqCodebook(
            dimension, subquantizers, centroids, values^
        )

    def version(self) -> UInt32:
        return _PQ_VERSION

    def dimension(self) -> Int:
        return self._dimension

    def subquantizer_count(self) -> Int:
        return self._subquantizers

    def centroid_count(self) -> Int:
        return self._centroids

    def subdimension(self) -> Int:
        return self._subdimension

    def encode(self, vector: List[Float32]) raises -> List[UInt8]:
        self._validate_vector(vector)
        var codes = List[UInt8](capacity=self._subquantizers)
        for subquantizer in range(self._subquantizers):
            codes.append(
                UInt8(
                    _nearest_pq_centroid(
                        vector,
                        subquantizer,
                        self._centroids,
                        self._subdimension,
                        self._values,
                    )
                )
            )
        return codes^

    def value(
        self, subquantizer: Int, centroid: Int, offset: Int
    ) raises -> Float32:
        if (
            subquantizer < 0
            or subquantizer >= self._subquantizers
            or centroid < 0
            or centroid >= self._centroids
            or offset < 0
            or offset >= self._subdimension
        ):
            raise Error("PQ centroid coordinate out of bounds")
        return self._values[
            _pq_offset(
                subquantizer,
                centroid,
                offset,
                self._centroids,
                self._subdimension,
            )
        ]

    def _validate_vector(self, vector: List[Float32]) raises:
        if len(vector) != self._dimension:
            raise Error("vector dimension does not match PQ codebook")
        for value in vector:
            if not isfinite(value):
                raise Error("PQ vectors must be finite")


struct PqIndex(Movable):
    """Immutable product-quantized dense index."""

    var _codebook: PqCodebook
    var _ids: List[Int]
    var _codes: List[UInt8]

    def __init__(
        out self,
        var codebook: PqCodebook,
        var ids: List[Int],
        var codes: List[UInt8],
    ) raises:
        if len(codes) != len(ids) * codebook.subquantizer_count():
            raise Error("PQ code payload length mismatch")
        self._codebook = codebook^
        self._ids = ids^
        self._codes = codes^

    @staticmethod
    def build(
        ids: List[Int],
        vectors: List[List[Float32]],
        subquantizers: Int,
        centroids: Int,
        *,
        iterations: Int = 8,
    ) raises -> PqIndex:
        if len(ids) != len(vectors):
            raise Error("PQ IDs and vectors must have equal lengths")
        var codebook = PqCodebook.train(
            vectors, subquantizers, centroids, iterations=iterations
        )
        var owned_ids = List[Int](capacity=len(ids))
        var codes = List[UInt8](
            capacity=len(ids) * codebook.subquantizer_count()
        )
        for row in range(len(ids)):
            for previous in range(row):
                if ids[previous] == ids[row]:
                    raise Error("PQ point IDs must be unique")
            owned_ids.append(ids[row])
            var encoded = codebook.encode(vectors[row])
            for code in encoded:
                codes.append(code)
        return PqIndex(codebook^, owned_ids^, codes^)

    def point_count(self) -> Int:
        return len(self._ids)

    def encoded_bytes(self) -> Int:
        return len(self._codes)

    def search_dot(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, _DOT_METRIC)

    def search_l2(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, _L2_METRIC)

    def search_cosine(
        self, query: List[Float32], k: Int
    ) raises -> List[SearchResult]:
        return self._search(query, k, _COSINE_METRIC)

    def _search(
        self, query: List[Float32], k: Int, metric: Int
    ) raises -> List[SearchResult]:
        self._validate_query(query, k, metric)
        var result_count = min(k, len(self._ids))
        if result_count == 0:
            return List[SearchResult]()
        var topk = BoundedTopK(
            result_count, smaller_is_better=metric == _L2_METRIC
        )
        for row in range(len(self._ids)):
            topk.offer(self._ids[row], self._score(query, row, metric))
        var retained = topk.sorted_entries()
        var output = List[SearchResult](capacity=len(retained))
        for entry in retained:
            output.append(SearchResult(entry.id, entry.score))
        return output^

    def _score(
        self, query: List[Float32], row: Int, metric: Int
    ) raises -> Float32:
        var score: Float32 = 0.0
        var query_norm: Float32 = 0.0
        var candidate_norm: Float32 = 0.0
        var subdimension = self._codebook.subdimension()
        var subquantizers = self._codebook.subquantizer_count()
        for subquantizer in range(subquantizers):
            var centroid = Int(
                self._codes[row * subquantizers + subquantizer]
            )
            for offset in range(subdimension):
                var column = subquantizer * subdimension + offset
                var candidate = self._codebook.value(
                    subquantizer, centroid, offset
                )
                if metric == _L2_METRIC:
                    var delta = query[column] - candidate
                    score += delta * delta
                else:
                    score += query[column] * candidate
                    if metric == _COSINE_METRIC:
                        query_norm += query[column] * query[column]
                        candidate_norm += candidate * candidate
        if metric == _COSINE_METRIC:
            if candidate_norm == 0.0:
                raise Error("cosine similarity requires non-zero vectors")
            return score / (sqrt(query_norm) * sqrt(candidate_norm))
        return score

    def _validate_query(
        self, query: List[Float32], k: Int, metric: Int
    ) raises:
        if len(query) != self._codebook.dimension():
            raise Error("query dimension does not match PQ index")
        if k <= 0:
            raise Error("k must be positive")
        var norm: Float32 = 0.0
        for value in query:
            if not isfinite(value):
                raise Error("query vector must be finite")
            norm += value * value
        if metric == _COSINE_METRIC and norm == 0.0:
            raise Error("cosine similarity requires non-zero vectors")


def _pq_offset(
    subquantizer: Int,
    centroid: Int,
    offset: Int,
    centroids: Int,
    subdimension: Int,
) -> Int:
    return (
        (subquantizer * centroids + centroid) * subdimension + offset
    )


def _nearest_pq_centroid(
    vector: List[Float32],
    subquantizer: Int,
    centroids: Int,
    subdimension: Int,
    values: List[Float32],
) -> Int:
    var nearest = 0
    var nearest_distance: Float32 = 0.0
    for centroid in range(centroids):
        var distance: Float32 = 0.0
        for offset in range(subdimension):
            var delta = vector[subquantizer * subdimension + offset] - values[
                _pq_offset(
                    subquantizer,
                    centroid,
                    offset,
                    centroids,
                    subdimension,
                )
            ]
            distance += delta * delta
        if centroid == 0 or distance < nearest_distance:
            nearest = centroid
            nearest_distance = distance
    return nearest
