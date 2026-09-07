from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.dispatch import (
    DistanceDispatchCounters,
    select_distance_backend,
)
from akasha.index.hnsw_storage import HnswStorage
from std.math import abs
from std.time import perf_counter_ns


def bench[tag: Int](dimension: Int) raises:
    var config = CollectionConfig.defaults(dimension)
    config.scalar_kind = ScalarKind.f32()
    comptime if tag >= 9:
        config.scalar_kind = ScalarKind.i8()
    elif tag >= 6:
        config.scalar_kind = ScalarKind.f16()
    elif tag >= 3:
        config.scalar_kind = ScalarKind.bf16()
    config.ann_metric = MetricKind.dot()
    comptime if tag < 9 and tag % 3 == 1:
        config.ann_metric = MetricKind.l2()
    elif (tag < 9 and tag % 3 == 2) or tag == 10:
        config.ann_metric = MetricKind.cosine()
    var counters = DistanceDispatchCounters()
    var backend = select_distance_backend(config, counters)
    var dispatcher = backend.dispatcher()
    var storage = HnswStorage(
        dimension,
        1,
        1,
        scalar_kind=config.scalar_kind,
        metric_kind=config.ann_metric,
    )
    var vectors = List[List[Float32]]()
    var query = List[Float32]()
    for slot in range(32):
        var values = List[Float32]()
        for column in range(dimension):
            values.append(Float32((slot * 13 + column * 7) % 29 - 14) * 0.0625)
        if slot == 0:
            query = backend.prepare_query(values)
        var prepared = backend.prepare_graph_vector(values)
        _ = storage.append(slot, prepared.copy(), 0)
        vectors.append(prepared^)
    for slot in range(32):
        var expected = backend.scalar_reference_prepared(query, vectors[slot])
        var actual = storage._distance_to_slot_backend[tag](
            dispatcher, query, UInt32(slot)
        )
        if abs(actual - expected) > 1.0e-3:
            raise Error("compact benchmark query oracle mismatch")
    for sample in range(5):
        var checksum: Float32 = 0.0
        var start = perf_counter_ns()
        for iteration in range(2000):
            checksum += storage._distance_to_slot_backend[tag](
                dispatcher, query, UInt32(iteration % 32)
            )
        var query_ns = perf_counter_ns() - start
        start = perf_counter_ns()
        for iteration in range(2000):
            checksum += storage._distance_between_backend[tag](
                dispatcher, UInt32(iteration % 32), UInt32((iteration + 7) % 32)
            )
        print(
            "compact tag="
            + String(tag)
            + " dimension="
            + String(dimension)
            + " sample="
            + String(sample)
            + " query_ns="
            + String(Float64(query_ns) / 2000.0)
            + " member_ns="
            + String(Float64(perf_counter_ns() - start) / 2000.0)
            + " checksum="
            + String(checksum)
        )


def main() raises:
    for dimension in [31, 384, 768, 1536]:
        comptime for tag in range(11):
            bench[tag](dimension)
