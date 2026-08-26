from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.simd import (
    _simd_dot_product_unchecked,
    _simd_l2_squared_unchecked,
)
from std.math import isfinite, sqrt


comptime _UINT32_MAX_AS_INT = 4_294_967_295
comptime _FLOAT32_MAX_AS_FLOAT64 = 3.4028234663852886e38
comptime _ACCUMULATION_SAFETY_FACTOR = 8.0
comptime _COSINE_UNIT_NORM_TOLERANCE = 1.0e-3


struct MetricDispatcher(Copyable, Movable):
    """Own one collection's metric, scalar backend, and vector dimension.

    Public boundary methods validate dimensions and finite values. Dot and L2
    also enforce a dimension-dependent component bound so their Float32 SIMD
    accumulations remain finite. Cosine uses Float64 boundary math and stores
    unit-normalized Float32 graph vectors. HNSW may call
    `_canonical_prepared_unchecked` only with vectors prepared by this
    dispatcher (or an equivalent durable codec).
    """

    var _metric: MetricKind
    var _scalar: ScalarKind
    var _dimension: Int

    def __init__(
        out self,
        metric: MetricKind,
        scalar: ScalarKind,
        dimension: Int,
    ) raises:
        if dimension <= 0:
            raise Error("dimension must be positive")
        if dimension > _UINT32_MAX_AS_INT:
            raise Error("dimension must fit UInt32")
        if not metric.is_valid():
            raise Error("metric has an unknown tag")
        if not scalar.is_valid():
            raise Error("scalar has an unknown tag")
        if scalar == ScalarKind.i8() and metric == MetricKind.l2():
            raise Error("scalar_kind i8 is not compatible with ann_metric l2")

        self._metric = metric.copy()
        self._scalar = scalar.copy()
        self._dimension = dimension

    def dimension(self) -> Int:
        return self._dimension

    def metric_name(self) -> String:
        return self._metric.name()

    def scalar_name(self) -> String:
        return self._scalar.name()

    def backend_name(self) -> String:
        if self._scalar == ScalarKind.f32():
            return "simd-f32"
        return "unimplemented"

    def validate_query(self, values: List[Float32]) raises:
        self._validate_values(values)
        if self._metric == MetricKind.cosine():
            self._require_nonzero_norm(values)

    def validate_vector(self, values: List[Float32]) raises:
        self._validate_values(values)
        if self._metric == MetricKind.cosine():
            self._require_nonzero_norm(values)

    def prepare_query(self, values: List[Float32]) raises -> List[Float32]:
        self.require_supported_backend()
        self.validate_query(values)
        return self._prepare_validated(values)

    def prepare_graph_vector(
        self, values: List[Float32]
    ) raises -> List[Float32]:
        self.require_supported_backend()
        self.validate_vector(values)
        return self._prepare_validated(values)

    def canonical(
        self, lhs: List[Float32], rhs: List[Float32]
    ) raises -> Float32:
        """Return lower-is-better distance for raw public vectors."""
        self.require_supported_backend()
        self.validate_query(lhs)
        self.validate_vector(rhs)

        if self._metric == MetricKind.l2():
            return self._require_finite_distance(
                _simd_l2_squared_unchecked(lhs, rhs)
            )
        if self._metric == MetricKind.dot():
            return self._require_finite_distance(
                -_simd_dot_product_unchecked(lhs, rhs)
            )

        var similarity = _stable_cosine_similarity(lhs, rhs)
        var distance = Float32(1.0 - _clamp_similarity_f64(similarity))
        return self._require_finite_distance(distance)

    def canonical_prepared(
        self, lhs: List[Float32], rhs: List[Float32]
    ) raises -> Float32:
        """Validate backend and prepared-vector invariants before scoring."""
        self.require_supported_backend()
        self._validate_prepared_values(lhs)
        self._validate_prepared_values(rhs)
        return self._require_finite_distance(
            self._canonical_prepared_unchecked(lhs, rhs)
        )

    def _canonical_prepared_unchecked(
        self, lhs: List[Float32], rhs: List[Float32]
    ) -> Float32:
        """Return canonical distance for prevalidated, prepared vectors.

        The dispatcher must use the F32 backend. Both inputs must be
        equal-length vectors prepared for this dispatcher; cosine inputs must
        be unit-normalized. This method performs no validation, allocation, or
        norm calculation. Vectors admitted by `prepare_query` and
        `prepare_graph_vector` guarantee a finite result; cosine is clamped so
        its canonical distance is always in the closed interval [0, 2].
        """
        if self._metric == MetricKind.l2():
            return _simd_l2_squared_unchecked(lhs, rhs)
        if self._metric == MetricKind.dot():
            return -_simd_dot_product_unchecked(lhs, rhs)
        return 1.0 - _clamp_similarity_f32(
            _simd_dot_product_unchecked(lhs, rhs)
        )

    def public_score(self, canonical_distance: Float32) -> Float32:
        """Convert a canonical distance back to the stable public score."""
        if self._metric == MetricKind.l2():
            return canonical_distance
        if self._metric == MetricKind.dot():
            return -canonical_distance
        return 1.0 - canonical_distance

    def require_supported_backend(self) raises:
        """Validate the backend once before entering a distance hot loop."""
        if self._scalar != ScalarKind.f32():
            raise Error("scalar backend not implemented")

    def _validate_values(self, values: List[Float32]) raises:
        if len(values) != self._dimension:
            raise Error("vector dimension does not match dispatcher")

        var component_limit = self._safe_component_limit()
        for i in range(self._dimension):
            if not isfinite(values[i]):
                raise Error("vectors must contain only finite values")
            if self._metric != MetricKind.cosine():
                var magnitude = Float64(values[i])
                if magnitude < 0.0:
                    magnitude = -magnitude
                if magnitude > component_limit:
                    raise Error(
                        "dot and l2 components exceed safe f32 accumulation"
                    )

    def _require_nonzero_norm(self, values: List[Float32]) raises:
        if _stable_norm(values) == 0.0:
            raise Error("cosine distance requires a non-zero vector")

    def _validate_prepared_values(self, values: List[Float32]) raises:
        self._validate_values(values)
        if self._metric != MetricKind.cosine():
            return

        var norm = _stable_norm(values)
        var error = norm - 1.0
        if error < 0.0:
            error = -error
        if error > _COSINE_UNIT_NORM_TOLERANCE:
            raise Error("prepared cosine vector must have unit norm")

    def _safe_component_limit(self) -> Float64:
        """Bound admitted dot/L2 inputs for finite Float32 accumulation.

        With B = sqrt(F32_MAX / (8 * dimension)), the absolute worst-case
        dot sum is at most F32_MAX / 8. The worst-case squared L2 sum, using
        component differences of 2B, is at most F32_MAX / 2. The remaining
        margin covers Float32 lane accumulation and reduction rounding.
        """
        return sqrt(
            _FLOAT32_MAX_AS_FLOAT64
            / (_ACCUMULATION_SAFETY_FACTOR * Float64(self._dimension))
        )

    def _require_finite_distance(self, distance: Float32) raises -> Float32:
        if not isfinite(distance):
            raise Error("metric distance must be finite")
        return distance

    def _prepare_validated(self, values: List[Float32]) raises -> List[Float32]:
        if self._metric != MetricKind.cosine():
            return values.copy()

        var norm = _stable_norm(values)
        var prepared = List[Float32](capacity=self._dimension)
        for i in range(self._dimension):
            var component = Float32(Float64(values[i]) / norm)
            if not isfinite(component):
                raise Error("prepared cosine vector must be finite")
            prepared.append(component)
        return prepared^


def _stable_norm(values: List[Float32]) -> Float64:
    """Return an underflow/overflow-resistant norm for finite Float32 data."""
    var squared_norm = Float64(0.0)
    for i in range(len(values)):
        var component = Float64(values[i])
        squared_norm += component * component
    return sqrt(squared_norm)


def _stable_cosine_similarity(
    lhs: List[Float32], rhs: List[Float32]
) -> Float64:
    var product = Float64(0.0)
    var lhs_squared_norm = Float64(0.0)
    var rhs_squared_norm = Float64(0.0)
    for i in range(len(lhs)):
        var left = Float64(lhs[i])
        var right = Float64(rhs[i])
        product += left * right
        lhs_squared_norm += left * left
        rhs_squared_norm += right * right

    var similarity = product / sqrt(lhs_squared_norm)
    return similarity / sqrt(rhs_squared_norm)


def _clamp_similarity_f64(similarity: Float64) -> Float64:
    if similarity < -1.0:
        return -1.0
    if similarity > 1.0:
        return 1.0
    return similarity


def _clamp_similarity_f32(similarity: Float32) -> Float32:
    if similarity < -1.0:
        return -1.0
    if similarity > 1.0:
        return 1.0
    return similarity
