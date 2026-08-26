from akasha.index.hnsw import HnswIndex
from std.time import perf_counter_ns


def main() raises:
    comptime dimension = 16
    comptime point_count = 1_000
    comptime iterations = 20
    var index = HnswIndex(dimension)
    for point_id in range(1, point_count + 1):
        var vector = List[Float32](capacity=dimension)
        for component in range(dimension):
            vector.append(Float32((point_id * 13 + component * 7) % 101) * 0.01)
        index.add(point_id, vector^)

    var query = List[Float32](capacity=dimension)
    for component in range(dimension):
        query.append(Float32((component * 11) % 37) * 0.02)
    var checksum = 0
    var start = perf_counter_ns()
    for _ in range(iterations):
        var results = index.search_dot(query, 10, 64)
        checksum += results[0].id
    var elapsed = perf_counter_ns() - start
    print(
        "HNSW search ns/query",
        Float64(elapsed) / Float64(iterations),
        "checksum",
        checksum,
    )
