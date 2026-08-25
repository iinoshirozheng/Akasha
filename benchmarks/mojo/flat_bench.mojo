from akasha.index.flat import FlatIndex
from std.time import perf_counter_ns


def main() raises:
    comptime dimension = 64
    comptime point_count = 10_000
    comptime iterations = 20
    comptime k = 10
    var index = FlatIndex(dimension)

    for point_id in range(point_count):
        var values = List[Float32](capacity=dimension)
        for component in range(dimension):
            values.append(Float32((point_id * 13 + component * 7) % 101) * 0.01)
        index.add(point_id, values^)

    var query = List[Float32](capacity=dimension)
    for component in range(dimension):
        query.append(Float32((component * 11) % 37) * 0.02)

    var checksum = 0
    var start = perf_counter_ns()
    for _ in range(iterations):
        var results = index.search_dot(query, k)
        checksum += results[0].id
    var elapsed = perf_counter_ns() - start

    print(
        "points",
        point_count,
        "dimension",
        dimension,
        "k",
        k,
        "iterations",
        iterations,
    )
    print(
        "flat search ns/query",
        Float64(elapsed) / Float64(iterations),
        "checksum",
        checksum,
    )
