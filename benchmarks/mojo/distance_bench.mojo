from akasha.compute.distance import dot_product
from akasha.compute.simd import simd_dot_product
from std.time import perf_counter_ns


def main() raises:
    comptime dimension = 768
    comptime iterations = 20_000
    var lhs = List[Float32](capacity=dimension)
    var rhs = List[Float32](capacity=dimension)
    for i in range(dimension):
        lhs.append(Float32(i % 17) * 0.125)
        rhs.append(Float32((i * 7) % 19) * 0.0625)

    var scalar_checksum: Float32 = 0.0
    var scalar_start = perf_counter_ns()
    for _ in range(iterations):
        scalar_checksum += dot_product(lhs, rhs)
    var scalar_elapsed = perf_counter_ns() - scalar_start

    var simd_checksum: Float32 = 0.0
    var simd_start = perf_counter_ns()
    for _ in range(iterations):
        simd_checksum += simd_dot_product(lhs, rhs)
    var simd_elapsed = perf_counter_ns() - simd_start

    print("dimension", dimension, "iterations", iterations)
    print(
        "scalar dot ns/call",
        Float64(scalar_elapsed) / Float64(iterations),
        "checksum",
        scalar_checksum,
    )
    print(
        "simd dot ns/call",
        Float64(simd_elapsed) / Float64(iterations),
        "checksum",
        simd_checksum,
    )
