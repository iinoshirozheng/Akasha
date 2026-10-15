from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult
from akasha.index.hnsw_level import splitmix64
from akasha.query.control import QueryControl
from std.math import abs, isfinite, sqrt


comptime _SQ8_VERSION = UInt32(2)
comptime _PQ_VERSION = UInt32(2)
comptime _DOT_METRIC = 0
comptime _L2_METRIC = 1
comptime _COSINE_METRIC = 2


struct Sq8Codebook(Movable):
    """Qdrant Int8 scalar quantizer: global offset/scale, codes 0..127.

    Source: lib/quantization/src/encoded_vectors_u8.rs at 21db2f3,
    Apache-2.0. Quantile clipping is not exposed by Akasha's SQ8 API.
    """

    var _dimension: Int
    var _minimum: Float32
    var _scale: Float32

    def __init__(
        out self,
        dimension: Int,
        minimum: Float32,
        scale: Float32,
    ) raises:
        if dimension <= 0:
            raise Error("SQ8 dimension must be positive")
        if not isfinite(minimum) or not isfinite(scale):
            raise Error("SQ8 codebook values must be finite")
        if scale < 0.0:
            raise Error("SQ8 scale cannot be negative")
        self._dimension = dimension
        self._minimum = minimum
        self._scale = scale

    @staticmethod
    def train(vectors: List[List[Float32]]) raises -> Sq8Codebook:
        if len(vectors) == 0 or len(vectors[0]) == 0:
            raise Error("SQ8 training requires non-empty vectors")
        var dimension = len(vectors[0])
        var minimum = vectors[0][0]
        var maximum = minimum
        for row in range(len(vectors)):
            if len(vectors[row]) != dimension:
                raise Error("SQ8 training vectors must share one dimension")
            for column in range(dimension):
                var value = vectors[row][column]
                if not isfinite(value):
                    raise Error("SQ8 training vectors must be finite")
                minimum = min(minimum, value)
                maximum = max(maximum, value)
        return Sq8Codebook(dimension, minimum, (maximum - minimum) / 127.0)

    def version(self) -> UInt32:
        return _SQ8_VERSION

    def dimension(self) -> Int:
        return self._dimension

    def minimum(self, column: Int) raises -> Float32:
        self._validate_column(column)
        return self._minimum

    def scale(self, column: Int) raises -> Float32:
        self._validate_column(column)
        return self._scale

    def encode(self, vector: List[Float32]) raises -> List[UInt8]:
        if len(vector) != self._dimension:
            raise Error("vector dimension does not match SQ8 codebook")
        var codes = List[UInt8](capacity=self._dimension)
        for column in range(self._dimension):
            var value = vector[column]
            if not isfinite(value):
                raise Error("SQ8 vectors must be finite")
            codes.append(self.encode_value(value))
        return codes^

    def encode_value(self, value: Float32) raises -> UInt8:
        if not isfinite(value):
            raise Error("SQ8 vectors must be finite")
        # Rust's saturating float-to-u8 conversion maps NaN to zero; this
        # handles a constant training population without producing NaN here.
        if self._scale == 0.0:
            return UInt8(127) if value > self._minimum else UInt8(0)
        var coordinate = (value - self._minimum) / self._scale
        if coordinate <= 0:
            return UInt8(0)
        if coordinate >= 126.5:
            return UInt8(127)
        return UInt8(Int(coordinate + 0.5))

    def decode(self, codes: List[UInt8]) raises -> List[Float32]:
        if len(codes) != self._dimension:
            raise Error("SQ8 code dimension mismatch")
        var vector = List[Float32](capacity=self._dimension)
        for column in range(self._dimension):
            vector.append(self.decode_value(column, codes[column]))
        return vector^

    def decode_value(self, column: Int, code: UInt8) raises -> Float32:
        self._validate_column(column)
        if code > 127:
            raise Error("SQ8 code exceeds the Int8 quantizer domain")
        return self._minimum + Float32(code) * self._scale

    def _validate_column(self, column: Int) raises:
        if column < 0 or column >= self._dimension:
            raise Error("SQ8 column out of bounds")


struct Sq8Index(Movable):
    """Immutable scalar-quantized dense index with deterministic Top-K."""

    var _codebook: Sq8Codebook
    var _ids: List[Int]
    var _codes: List[UInt8]
    var _dot_offsets: List[Float32]
    var _l2_offsets: List[Float32]
    var _cosine: Bool

    def __init__(
        out self,
        var codebook: Sq8Codebook,
        var ids: List[Int],
        var codes: List[UInt8],
        *,
        cosine: Bool = False,
    ) raises:
        if len(codes) != len(ids) * codebook.dimension():
            raise Error("SQ8 code payload length mismatch")
        self._codebook = codebook^
        self._ids = ids^
        self._codes = codes^
        self._cosine = cosine
        self._dot_offsets = List[Float32](capacity=len(self._ids))
        self._l2_offsets = List[Float32](capacity=len(self._ids))
        var alpha = self._codebook._scale
        var offset = self._codebook._minimum
        var padding = (16 - self.dimension() % 16) % 16
        var padding_code = Float32(self._codebook.encode_value(0))
        var shift = Float32(self.dimension() + padding) * offset * offset
        for row in range(len(self._ids)):
            var total = Float32(0)
            var squares = Float32(0)
            for column in range(self.dimension()):
                var code = self._codes[row * self.dimension() + column]
                if code > 127:
                    raise Error("SQ8 code exceeds the Int8 quantizer domain")
                var value = Float32(code)
                total += value
                squares += value * value
            for _ in range(padding):
                total += padding_code
            self._dot_offsets.append(shift + _sq8_affine_offset(total, alpha, offset))
            self._l2_offsets.append(squares * alpha * alpha)

    @staticmethod
    def build(
        ids: List[Int], vectors: List[List[Float32]], *, cosine: Bool = False
    ) raises -> Sq8Index:
        if cosine:
            var normalized = List[List[Float32]](capacity=len(vectors))
            for row in range(len(vectors)):
                normalized.append(_quantized_cosine_preprocess(vectors[row]))
            return Sq8Index._build_preprocessed(ids, normalized, True)
        return Sq8Index._build_preprocessed(ids, vectors, False)

    @staticmethod
    def _build_preprocessed(
        ids: List[Int], vectors: List[List[Float32]], cosine: Bool
    ) raises -> Sq8Index:
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
        return Sq8Index(codebook^, owned_ids^, codes^, cosine=cosine)

    def point_count(self) -> Int:
        return len(self._ids)

    def dimension(self) -> Int:
        return self._codebook.dimension()

    def encoded_bytes(self) -> Int:
        return len(self._codes)

    def estimated_bytes(self) -> Int:
        return len(self._codes) + len(self._ids) * 16 + 8

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
        var codes: List[UInt8]
        if metric == _COSINE_METRIC:
            codes = self._codebook.encode(_quantized_cosine_preprocess(query))
        else:
            codes = self._codebook.encode(query)
        var query_total = Float32(0)
        for code in codes:
            var value = Float32(code)
            query_total += value * value if metric == _L2_METRIC else value
        var alpha = self._codebook._scale
        var query_offset: Float32
        if metric == _L2_METRIC:
            query_offset = query_total * alpha * alpha
        else:
            var padding = (16 - self.dimension() % 16) % 16
            var padding_code = Float32(self._codebook.encode_value(0))
            for _ in range(padding):
                query_total += padding_code
            query_offset = query_total * alpha * self._codebook._minimum
        for row in range(len(self._ids)):
            topk.offer(self._ids[row], self._score(codes, query_offset, row, metric))
        var retained = topk.sorted_entries()
        var output = List[SearchResult](capacity=len(retained))
        for entry in retained:
            output.append(SearchResult(entry.id, entry.score))
        return output^

    def _score(
        self, query: List[UInt8], query_offset: Float32, row: Int, metric: Int
    ) raises -> Float32:
        var product = Int64(0)
        for column in range(self.dimension()):
            product += Int64(query[column]) * Int64(
                self._codes[row * self.dimension() + column]
            )
        var alpha = self._codebook._scale
        if metric == _L2_METRIC:
            # Qdrant's Euclid public boundary takes sqrt(abs(raw_score));
            # Akasha returns its square, including cancellation round-off.
            return abs(_sq8_scaled_product(-2.0 * alpha * alpha, product) + query_offset + self._l2_offsets[row])
        var padding = (16 - self.dimension() % 16) % 16
        var padding_code = Int64(self._codebook.encode_value(0))
        product += Int64(padding) * padding_code * padding_code
        return _sq8_scaled_product(alpha * alpha, product) + query_offset + self._dot_offsets[row]

    def _validate_query(self, query: List[Float32], k: Int, metric: Int) raises:
        if (metric == _COSINE_METRIC) != self._cosine:
            raise Error("SQ8 cosine queries require a cosine-preprocessed index")
        if len(query) != self.dimension():
            raise Error("query dimension does not match SQ8 index")
        if k <= 0:
            raise Error("k must be positive")
        for value in query:
            if not isfinite(value):
                raise Error("query vector must be finite")


@no_inline
def _sq8_affine_offset(total: Float32, alpha: Float32, offset: Float32) -> Float32:
    # Preserve the upstream F32 rounding boundary before adding its shift.
    # Inlining permits contraction with that addition and changes small scores.
    return total * alpha * offset


@no_inline
def _sq8_scaled_product(multiplier: Float32, product: Int64) -> Float32:
    # The Rust score path rounds this product before adding query/vector offsets.
    return multiplier * Float32(product)


def _quantized_cosine_preprocess(values: List[Float32]) raises -> List[Float32]:
    """Qdrant's F32 cosine preprocessing before quantization."""
    var length = Float32(0)
    for value in values:
        if not isfinite(value):
            raise Error("quantized cosine input must be finite")
        length += value * value
    if length < Float32(1.1920928955078125e-7) or abs(length - 1.0) <= 1.0e-6:
        return values.copy()
    length = sqrt(length)
    var normalized = List[Float32](capacity=len(values))
    for value in values:
        normalized.append(value / length)
    return normalized^


struct PqCodebook(Movable):
    """Qdrant serial Lloyd training with deterministic sampling/reseeding.

    Source: lib/quantization/src/{encoded_vectors_pq,kmeans}.rs at 21db2f3,
    Apache-2.0. Keep Akasha's explicit centroid and iteration parameters.
    """

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
        control: Optional[QueryControl] = None,
    ) raises -> PqCodebook:
        if len(vectors) == 0 or len(vectors[0]) == 0:
            raise Error("PQ training requires non-empty vectors")
        if control:
            control.value().validate_candidate_count(len(vectors))
            control.value().checkpoint(0)
        var dimension = len(vectors[0])
        if subquantizers <= 0 or dimension % subquantizers != 0:
            raise Error("PQ dimension must divide into subquantizers")
        if centroids <= 0 or centroids > 256 or centroids > len(vectors):
            raise Error("PQ centroid count exceeds supported training rows")
        if iterations <= 0:
            raise Error("PQ training iterations must be positive")
        for row in range(len(vectors)):
            if control:
                control.value().checkpoint(row)
            if len(vectors[row]) != dimension:
                raise Error("PQ training vectors must share one dimension")
            for value in vectors[row]:
                if not isfinite(value):
                    raise Error("PQ training vectors must be finite")

        # Upstream samples at most 10,000 rows, then restores source order.
        # A deterministic uniform reservoir replaces its random permutation.
        var sample_count = min(10_000, len(vectors))
        var sample = List[Int](capacity=sample_count)
        for row in range(sample_count):
            sample.append(row)
        var random_state = UInt64(1)
        for row in range(sample_count, len(vectors)):
            if control:
                control.value().checkpoint(row)
            var selected = _pq_random_index(random_state, row + 1)
            if selected < sample_count:
                sample[selected] = row
        sort(Span(sample))
        random_state = 1
        var subdimension = dimension // subquantizers
        var values = List[Float32](
            length=dimension * centroids, fill=Float32(0.0)
        )
        for subquantizer in range(subquantizers):
            for centroid in range(centroids):
                var source = sample[centroid]
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

        if len(vectors) == centroids:
            return PqCodebook(dimension, subquantizers, centroids, values^)
        # Each subvector converges independently, as in upstream kmeans.
        for subquantizer in range(subquantizers):
            for _ in range(iterations):
                if control:
                    control.value().checkpoint(0)
                var sums = List[Float64](
                    length=centroids * subdimension, fill=Float64(0)
                )
                var counts = List[Int](length=centroids, fill=0)
                for sample_row in range(sample_count):
                    if control:
                        control.value().checkpoint(sample_row)
                    var row = sample[sample_row]
                    var nearest = _nearest_pq_centroid(
                        vectors[row],
                        subquantizer,
                        centroids,
                        subdimension,
                        values,
                    )
                    counts[nearest] += 1
                    for offset in range(subdimension):
                        sums[nearest * subdimension + offset] += Float64(
                            vectors[row][subquantizer * subdimension + offset]
                        )
                var difference = Float32(0)
                for centroid in range(centroids):
                    var count = counts[centroid]
                    var replacement = 0
                    if count == 0:
                        replacement = sample[
                            _pq_random_index(random_state, sample_count)
                        ]
                    for offset in range(subdimension):
                        var index = _pq_offset(
                            subquantizer,
                            centroid,
                            offset,
                            centroids,
                            subdimension,
                        )
                        var value = (
                            vectors[replacement][subquantizer * subdimension + offset]
                            if count == 0 else Float32(
                                sums[centroid * subdimension + offset] / Float64(count)
                            )
                        )
                        difference += abs(values[index] - value)
                        values[index] = value
                if difference < Float32(1.0e-5):
                    break
        if control:
            control.value().checkpoint(0)
        return PqCodebook(dimension, subquantizers, centroids, values^)

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
    var _cosine: Bool

    def __init__(
        out self,
        var codebook: PqCodebook,
        var ids: List[Int],
        var codes: List[UInt8],
        *,
        cosine: Bool = False,
    ) raises:
        if len(codes) != len(ids) * codebook.subquantizer_count():
            raise Error("PQ code payload length mismatch")
        for code in codes:
            if Int(code) >= codebook.centroid_count():
                raise Error("PQ code exceeds the centroid count")
        self._codebook = codebook^
        self._ids = ids^
        self._codes = codes^
        self._cosine = cosine

    @staticmethod
    def build(
        ids: List[Int],
        vectors: List[List[Float32]],
        subquantizers: Int,
        centroids: Int,
        *,
        iterations: Int = 8,
        control: Optional[QueryControl] = None,
        cosine: Bool = False,
    ) raises -> PqIndex:
        if cosine:
            if control:
                control.value().validate_candidate_count(len(vectors))
                control.value().checkpoint(0)
            var normalized = List[List[Float32]](capacity=len(vectors))
            for row in range(len(vectors)):
                if control:
                    control.value().checkpoint(row)
                normalized.append(_quantized_cosine_preprocess(vectors[row]))
            return PqIndex._build_preprocessed(
                ids, normalized, subquantizers, centroids, iterations, control, True
            )
        return PqIndex._build_preprocessed(
            ids, vectors, subquantizers, centroids, iterations, control, False
        )

    @staticmethod
    def _build_preprocessed(
        ids: List[Int], vectors: List[List[Float32]],
        subquantizers: Int, centroids: Int, iterations: Int,
        control: Optional[QueryControl], cosine: Bool,
    ) raises -> PqIndex:
        if len(ids) != len(vectors):
            raise Error("PQ IDs and vectors must have equal lengths")
        var codebook = PqCodebook.train(
            vectors,
            subquantizers,
            centroids,
            iterations=iterations,
            control=control,
        )
        var owned_ids = List[Int](capacity=len(ids))
        var codes = List[UInt8](
            capacity=len(ids) * codebook.subquantizer_count()
        )
        for row in range(len(ids)):
            if control:
                control.value().checkpoint(row)
            for previous in range(row):
                if ids[previous] == ids[row]:
                    raise Error("PQ point IDs must be unique")
            owned_ids.append(ids[row])
            var encoded = codebook.encode(vectors[row])
            for code in encoded:
                codes.append(code)
        if control:
            control.value().checkpoint(0)
        return PqIndex(codebook^, owned_ids^, codes^, cosine=cosine)

    def point_count(self) -> Int:
        return len(self._ids)

    def encoded_bytes(self) -> Int:
        return len(self._codes)

    def estimated_bytes(self) -> Int:
        return (
            len(self._codes)
            + len(self._ids) * 8
            + self._codebook.dimension() * self._codebook.centroid_count() * 4
        )

    def search_dot(
        self,
        query: List[Float32],
        k: Int,
        *,
        control: Optional[QueryControl] = None,
    ) raises -> List[SearchResult]:
        return self._search(query, k, _DOT_METRIC, control)

    def search_l2(
        self,
        query: List[Float32],
        k: Int,
        *,
        control: Optional[QueryControl] = None,
    ) raises -> List[SearchResult]:
        return self._search(query, k, _L2_METRIC, control)

    def search_cosine(
        self,
        query: List[Float32],
        k: Int,
        *,
        control: Optional[QueryControl] = None,
    ) raises -> List[SearchResult]:
        return self._search(query, k, _COSINE_METRIC, control)

    def _search(
        self,
        query: List[Float32],
        k: Int,
        metric: Int,
        control: Optional[QueryControl],
    ) raises -> List[SearchResult]:
        self._validate_query(query, k, metric)
        if control:
            control.value().validate_candidate_count(len(self._ids))
            control.value().checkpoint(0)
        var result_count = min(k, len(self._ids))
        if result_count == 0:
            return List[SearchResult]()
        var topk = BoundedTopK(
            result_count, smaller_is_better=metric == _L2_METRIC
        )
        var lookup: List[Float32]
        if metric == _COSINE_METRIC:
            lookup = self._query_lookup(_quantized_cosine_preprocess(query), metric, control)
        else:
            lookup = self._query_lookup(query, metric, control)
        for row in range(len(self._ids)):
            if control:
                control.value().checkpoint(row)
            topk.offer(self._ids[row], self._score(lookup, row))
        var retained = topk.sorted_entries()
        var output = List[SearchResult](capacity=len(retained))
        for entry in retained:
            output.append(SearchResult(entry.id, entry.score))
        if control:
            control.value().checkpoint(0)
        return output^

    def _query_lookup(
        self, query: List[Float32], metric: Int,
        control: Optional[QueryControl],
    ) raises -> List[Float32]:
        """Qdrant EncodedVectorsPQ::encode_query: score each centroid once."""
        var subdimension = self._codebook.subdimension()
        var subquantizers = self._codebook.subquantizer_count()
        var centroids = self._codebook.centroid_count()
        var lookup = List[Float32](capacity=subquantizers * centroids)
        for subquantizer in range(subquantizers):
            for centroid in range(centroids):
                if control:
                    control.value().checkpoint(centroid)
                var score = Float32(0)
                for offset in range(subdimension):
                    var column = subquantizer * subdimension + offset
                    var candidate = self._codebook.value(subquantizer, centroid, offset)
                    if metric == _L2_METRIC:
                        var delta = query[column] - candidate
                        score += delta * delta
                    else:
                        score += query[column] * candidate
                lookup.append(score)
        return lookup^

    def _score(self, lookup: List[Float32], row: Int) -> Float32:
        var score = Float32(0)
        var subquantizers = self._codebook.subquantizer_count()
        var centroids = self._codebook.centroid_count()
        for subquantizer in range(subquantizers):
            var code = Int(self._codes[row * subquantizers + subquantizer])
            score += lookup[subquantizer * centroids + code]
        return score

    def _validate_query(self, query: List[Float32], k: Int, metric: Int) raises:
        if (metric == _COSINE_METRIC) != self._cosine:
            raise Error("PQ cosine queries require a cosine-preprocessed index")
        if len(query) != self._codebook.dimension():
            raise Error("query dimension does not match PQ index")
        if k <= 0:
            raise Error("k must be positive")
        for value in query:
            if not isfinite(value):
                raise Error("query vector must be finite")


def _pq_random_index(mut state: UInt64, count: Int) -> Int:
    var bound = UInt64(count)
    var limit = UInt64.MAX - UInt64.MAX % bound
    var value = splitmix64(state)
    state += UInt64(0x9E3779B97F4A7C15)
    while value >= limit:
        value = splitmix64(state)
        state += UInt64(0x9E3779B97F4A7C15)
    return Int(value % bound)


def _pq_offset(
    subquantizer: Int,
    centroid: Int,
    offset: Int,
    centroids: Int,
    subdimension: Int,
) -> Int:
    return (subquantizer * centroids + centroid) * subdimension + offset


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
            var delta = (
                vector[subquantizer * subdimension + offset]
                - values[
                    _pq_offset(
                        subquantizer,
                        centroid,
                        offset,
                        centroids,
                        subdimension,
                    )
                ]
            )
            distance += delta * delta
        if centroid == 0 or distance < nearest_distance:
            nearest = centroid
            nearest_distance = distance
    return nearest
