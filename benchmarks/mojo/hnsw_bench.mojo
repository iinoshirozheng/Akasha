from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from std.time import perf_counter_ns


def main() raises:
    comptime dimension = 16
    comptime point_count = 1_000
    comptime iterations = 20
    comptime ef_search = 64
    var config = CollectionConfig.defaults(dimension)
    config.ann_metric = MetricKind.l2()
    var index = HnswIndex(config.copy())
    for point_id in range(1, point_count + 1):
        var vector = List[Float32](capacity=dimension)
        for component in range(dimension):
            vector.append(Float32((point_id * 13 + component * 7) % 101) * 0.01)
        index.add(point_id, vector^)

    var query = List[Float32](capacity=dimension)
    for component in range(dimension):
        query.append(Float32((component * 11) % 37) * 0.02)
    var checksum = 0
    var total_visited = 0
    var start = perf_counter_ns()
    for _ in range(iterations):
        var results = index.search(query, 10, ef_search=ef_search)
        checksum += results[0].id
        total_visited += index.last_search_visited()
    var elapsed = perf_counter_ns() - start
    print(
        "HNSW metric",
        config.metric_name(),
        "scalar",
        config.scalar_name(),
        "backend",
        index.distance_backend.backend_name(),
        "M",
        config.m,
        "M0",
        config.m0,
        "efConstruction",
        config.ef_construction,
        "efSearch",
        ef_search,
        "build distances",
        index.build_distance_evaluations(),
        "avg visited",
        Float64(total_visited) / Float64(iterations),
        "search ns/query",
        Float64(elapsed) / Float64(iterations),
        "checksum",
        checksum,
    )
