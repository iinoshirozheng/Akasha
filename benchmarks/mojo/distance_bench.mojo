from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.dispatch import (
    DISTANCE_DISPATCH_PUBLIC_BOUNDARY,
    DISTANCE_DOT_F32,
    DISTANCE_DOT_I8,
    DistanceBackend,
    DistanceDispatchCounters,
    record_distance_dispatch,
    select_distance_backend,
)
from akasha.index.hnsw_storage import HnswStorage
from std.time import perf_counter_ns


struct _Timing:
    var elapsed_ns: Int
    var checksum: Float32
    var actual: Float32

    def __init__(out self, elapsed_ns: Int, checksum: Float32, actual: Float32):
        self.elapsed_ns = elapsed_ns
        self.checksum = checksum
        self.actual = actual


def _time_selected_storage_kernel[
    backend_tag: Int
](
    storage: HnswStorage,
    backend: DistanceBackend,
    query: List[Float32],
    iterations: Int,
) raises -> _Timing:
    """Time only the compile-time-selected packed-storage distance kernel."""
    var dispatcher = backend.dispatcher()
    var actual = storage._distance_to_slot_backend[backend_tag](
        dispatcher, query, UInt32(0)
    )
    var checksum = Float32(0.0)
    var started = perf_counter_ns()
    for _ in range(iterations):
        checksum += storage._distance_to_slot_backend[backend_tag](
            dispatcher, query, UInt32(0)
        )
    return _Timing(perf_counter_ns() - started, checksum, actual)


def _bench_identity(config: CollectionConfig, iterations: Int) raises:
    var counters = DistanceDispatchCounters()
    var backend = select_distance_backend(config, counters)
    var lhs = List[Float32](capacity=config.dimension)
    var rhs = List[Float32](capacity=config.dimension)
    for i in range(config.dimension):
        lhs.append(Float32(i % 17) * 0.125 - 0.75)
        rhs.append(Float32((i * 7) % 19) * 0.0625 - 0.5)
    var prepared_query = backend.prepare_query(lhs)
    var prepared_vector = backend.prepare_graph_vector(rhs)
    var storage = HnswStorage(
        config.dimension,
        1,
        1,
        scalar_kind=config.scalar_kind,
        metric_kind=config.ann_metric,
    )
    _ = storage.append(1, prepared_vector.copy(), 0)

    # The timed loop receives a comptime tag after this single runtime match.
    record_distance_dispatch(counters, DISTANCE_DISPATCH_PUBLIC_BOUNDARY)
    var timing: _Timing
    if backend.tag() == DISTANCE_DOT_F32:
        timing = _time_selected_storage_kernel[DISTANCE_DOT_F32](
            storage, backend, prepared_query, iterations
        )
    elif backend.tag() == DISTANCE_DOT_I8:
        timing = _time_selected_storage_kernel[DISTANCE_DOT_I8](
            storage, backend, prepared_query, iterations
        )
    else:
        raise Error("distance benchmark identity is not enabled")

    var reference = backend.scalar_reference_prepared(
        prepared_query, prepared_vector
    )
    var difference = timing.actual - reference
    if difference < 0.0:
        difference = -difference
    if difference > 1.0e-3:
        raise Error(
            "selected distance benchmark diverged from scalar reference"
        )
    print(
        "metric",
        backend.metric_name(),
        "scalar",
        backend.scalar_name(),
        "backend",
        backend.backend_name(),
        "selections",
        counters.selection_count(),
        "public_switches",
        counters.public_boundary_switch_count(),
        "hot_loop_selections",
        counters.hot_loop_selection_count(),
        "dimension",
        config.dimension,
        "iterations",
        iterations,
        "ns/call",
        Float64(timing.elapsed_ns) / Float64(iterations),
        "checksum",
        timing.checksum,
        "reference",
        reference,
    )


def main() raises:
    comptime dimension = 768
    comptime iterations = 20_000
    var f32 = CollectionConfig.defaults(dimension)
    f32.ann_metric = MetricKind.dot()
    f32.scalar_kind = ScalarKind.f32()
    _bench_identity(f32, iterations)
    var i8 = f32.copy()
    i8.scalar_kind = ScalarKind.i8()
    _bench_identity(i8, iterations)
