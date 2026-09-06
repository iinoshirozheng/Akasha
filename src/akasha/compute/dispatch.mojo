from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.compute.quantization import scaled_i8_accumulator
from std.sys import simd_width_of


comptime DISTANCE_DOT_F32 = 0
comptime DISTANCE_L2_F32 = 1
comptime DISTANCE_COSINE_F32 = 2
comptime DISTANCE_DOT_BF16 = 3
comptime DISTANCE_L2_BF16 = 4
comptime DISTANCE_COSINE_BF16 = 5
comptime DISTANCE_DOT_F16 = 6
comptime DISTANCE_L2_F16 = 7
comptime DISTANCE_COSINE_F16 = 8
comptime DISTANCE_DOT_I8 = 9
comptime DISTANCE_COSINE_I8 = 10


def finish_distance[
    backend_tag: Int
](product: Float32, squared_l2: Float32) -> Float32:
    """Finish one specialized canonical distance without runtime dispatch."""
    comptime if (
        backend_tag == DISTANCE_L2_F32
        or backend_tag == DISTANCE_L2_BF16
        or backend_tag == DISTANCE_L2_F16
    ):
        return squared_l2
    elif (
        backend_tag == DISTANCE_DOT_F32
        or backend_tag == DISTANCE_DOT_BF16
        or backend_tag == DISTANCE_DOT_F16
        or backend_tag == DISTANCE_DOT_I8
    ):
        return -product
    else:
        if product < -1.0:
            return 2.0
        if product > 1.0:
            return 0.0
        return 1.0 - product


def portable_simd_width() -> Int:
    """Return the native Float32 lane count compiled into this binary."""
    return simd_width_of[DType.float32]()


struct DistanceExecutionStats(Movable, Writable):
    """Common execution labels and counters across vector-search paths."""

    var backend_name: String
    var metric_name: String
    var scalar_name: String
    var fallback_reason: String
    var requested_ef: Int
    var effective_ef: Int
    var visited: Int
    var distance_evaluations: Int

    def __init__(
        out self,
        backend_name: String,
        metric_name: String,
        scalar_name: String,
        fallback_reason: String,
        requested_ef: Int,
        effective_ef: Int,
        visited: Int,
        distance_evaluations: Int,
    ):
        self.backend_name = String(copy=backend_name)
        self.metric_name = String(copy=metric_name)
        self.scalar_name = String(copy=scalar_name)
        self.fallback_reason = String(copy=fallback_reason)
        self.requested_ef = requested_ef
        self.effective_ef = effective_ef
        self.visited = visited
        self.distance_evaluations = distance_evaluations


struct DistanceDispatchCounters(Copyable, Movable):
    """Per-owner evidence that dispatch stays outside distance hot loops."""

    var _selection_count: Int
    var _public_boundary_switch_count: Int
    var _hot_loop_selection_count: Int

    def __init__(out self):
        self._selection_count = 0
        self._public_boundary_switch_count = 0
        self._hot_loop_selection_count = 0

    def record_selection(mut self):
        self._selection_count += 1

    def record_public_boundary_switch(mut self):
        self._public_boundary_switch_count += 1

    def selection_count(self) -> Int:
        return self._selection_count

    def public_boundary_switch_count(self) -> Int:
        return self._public_boundary_switch_count

    def hot_loop_selection_count(self) -> Int:
        return self._hot_loop_selection_count


struct DistanceBackend(Copyable, Movable):
    """One construction-time metric/scalar selection.

    Mojo 1.0 cannot store a trait-typed function value in a struct field.  The
    selected integer tag is therefore consumed by parameterized HNSW cores at
    public operation boundaries; it is never redispatched by a distance loop.
    """

    var _dispatcher: MetricDispatcher
    var _tag: Int

    def __init__(out self, dispatcher: MetricDispatcher, tag: Int):
        self._dispatcher = dispatcher.copy()
        self._tag = tag

    def tag(self) -> Int:
        return self._tag

    def backend_name(self) -> String:
        return String("portable-simd-", portable_simd_width())

    def metric_name(self) -> String:
        return self._dispatcher.metric_name()

    def scalar_name(self) -> String:
        return self._dispatcher.scalar_name()

    def dimension(self) -> Int:
        return self._dispatcher.dimension()

    def dispatcher(self) -> MetricDispatcher:
        return self._dispatcher.copy()

    def prepare_query(self, values: List[Float32]) raises -> List[Float32]:
        return self._dispatcher.prepare_query(values)

    def prepare_graph_vector(
        self, values: List[Float32]
    ) raises -> List[Float32]:
        return self._dispatcher.prepare_graph_vector(values)

    def canonical_prepared(
        self, lhs: List[Float32], rhs: List[Float32]
    ) raises -> Float32:
        return self._dispatcher.canonical_prepared(lhs, rhs)

    def scalar_reference_prepared(
        self, lhs: List[Float32], rhs: List[Float32]
    ) raises -> Float32:
        """Reference the selected prepared representation with scalar loops."""
        self._dispatcher.validate_prepared_vector(lhs)
        self._dispatcher.validate_prepared_vector(rhs)
        if self.scalar_name() == "i8":
            var accumulator = Int32(0)
            for component in range(self._dispatcher.dimension()):
                accumulator += Int32(lhs[component]) * Int32(rhs[component])
            var product = scaled_i8_accumulator(
                accumulator,
                lhs[self._dispatcher.dimension()],
                rhs[self._dispatcher.dimension()],
            )
            return self._dispatcher._finish_prepared_f32_accumulations(
                product, 0.0
            )

        var product = Float32(0.0)
        var squared_l2 = Float32(0.0)
        for component in range(self._dispatcher.dimension()):
            var left = lhs[component]
            var right = rhs[component]
            product += left * right
            var difference = left - right
            squared_l2 += difference * difference
        return self._dispatcher._finish_prepared_f32_accumulations(
            product, squared_l2
        )


def select_distance_backend(
    config: CollectionConfig, mut counters: DistanceDispatchCounters
) raises -> DistanceBackend:
    """Select one enabled metric/scalar combination for an index."""
    var dispatcher = MetricDispatcher(
        config.ann_metric, config.scalar_kind, config.dimension
    )
    var tag: Int
    if config.scalar_kind == ScalarKind.f32():
        if config.ann_metric == MetricKind.dot():
            tag = DISTANCE_DOT_F32
        elif config.ann_metric == MetricKind.l2():
            tag = DISTANCE_L2_F32
        else:
            tag = DISTANCE_COSINE_F32
    elif config.scalar_kind == ScalarKind.bf16():
        if config.ann_metric == MetricKind.dot():
            tag = DISTANCE_DOT_BF16
        elif config.ann_metric == MetricKind.l2():
            tag = DISTANCE_L2_BF16
        else:
            tag = DISTANCE_COSINE_BF16
    elif config.scalar_kind == ScalarKind.f16():
        if config.ann_metric == MetricKind.dot():
            tag = DISTANCE_DOT_F16
        elif config.ann_metric == MetricKind.l2():
            tag = DISTANCE_L2_F16
        else:
            tag = DISTANCE_COSINE_F16
    elif config.ann_metric == MetricKind.dot():
        tag = DISTANCE_DOT_I8
    else:
        tag = DISTANCE_COSINE_I8
    counters.record_selection()
    return DistanceBackend(dispatcher^, tag)
