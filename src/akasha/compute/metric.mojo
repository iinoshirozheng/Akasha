from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.simd import (
    simd_dot_product_unchecked,
    simd_l2_squared_unchecked,
)
from std.math import isfinite, sqrt


comptime _UINT32_MAX_AS_INT = 4_294_967_295


struct MetricDispatcher(Copyable, Movable):
    """Own one collection's metric, scalar backend, and vector dimension.

    Public boundary methods validate dimensions and finite values. HNSW may
    call `canonical_prepared_unchecked` only with vectors prepared by this
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
            return simd_l2_squared_unchecked(lhs, rhs)
        if self._metric == MetricKind.dot():
            return -simd_dot_product_unchecked(lhs, rhs)

        var product = simd_dot_product_unchecked(lhs, rhs)
        var lhs_norm_squared = simd_dot_product_unchecked(lhs, lhs)
        var rhs_norm_squared = simd_dot_product_unchecked(rhs, rhs)
        return 1.0 - product / sqrt(lhs_norm_squared * rhs_norm_squared)

    def canonical_prepared(
        self, lhs: List[Float32], rhs: List[Float32]
    ) raises -> Float32:
        """Check backend support, then score already-prepared vectors."""
        self.require_supported_backend()
        return self.canonical_prepared_unchecked(lhs, rhs)

    def canonical_prepared_unchecked(
        self, lhs: List[Float32], rhs: List[Float32]
    ) -> Float32:
        """Return canonical distance for prevalidated, prepared vectors.

        The dispatcher must use the F32 backend. Both inputs must be
        equal-length vectors prepared for this dispatcher; cosine inputs must
        be unit-normalized. This method performs no validation, allocation, or
        norm calculation.
        """
        if self._metric == MetricKind.l2():
            return simd_l2_squared_unchecked(lhs, rhs)
        if self._metric == MetricKind.dot():
            return -simd_dot_product_unchecked(lhs, rhs)
        return 1.0 - simd_dot_product_unchecked(lhs, rhs)

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
        for i in range(self._dimension):
            if not isfinite(values[i]):
                raise Error("vectors must contain only finite values")

    def _require_nonzero_norm(self, values: List[Float32]) raises:
        if simd_dot_product_unchecked(values, values) == 0.0:
            raise Error("cosine distance requires a non-zero vector")

    def _prepare_validated(self, values: List[Float32]) -> List[Float32]:
        if self._metric != MetricKind.cosine():
            return values.copy()

        var norm = sqrt(simd_dot_product_unchecked(values, values))
        var prepared = List[Float32](capacity=self._dimension)
        for i in range(self._dimension):
            prepared.append(values[i] / norm)
        return prepared^
