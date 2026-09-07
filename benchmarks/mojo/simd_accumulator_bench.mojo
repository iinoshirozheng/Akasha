from akasha.compute.simd import _dot_kernel, _l2_kernel
from std.math import abs
from std.sys import simd_width_of
from std.time import perf_counter_ns


@no_inline
def score[
    accumulators: Int, metric: Int
](lhs: List[Float32], rhs: List[Float32]) -> Float32:
    comptime if metric == 0:
        return _dot_kernel[simd_width_of[DType.float32]() * accumulators](
            lhs, rhs
        )
    else:
        return _l2_kernel[simd_width_of[DType.float32]() * accumulators](
            lhs, rhs
        )


def bench[accumulators: Int, metric: Int](dimension: Int) raises:
    var lhs = List[Float32]()
    var rhs = List[Float32]()
    for i in range(dimension):
        lhs.append(Float32(i % 17 - 8) / 8.0)
        rhs.append(Float32(i % 13 - 6) / 16.0)
    var expected = score[1, metric](lhs, rhs)
    if abs(score[accumulators, metric](lhs, rhs) - expected) > 1.0e-4:
        raise Error("accumulator oracle mismatch")
    for sample in range(5):
        var total: Float32 = 0.0
        var start = perf_counter_ns()
        for _ in range(20000):
            total += score[accumulators, metric](lhs, rhs)
        print(
            "metric="
            + String(metric)
            + " accumulators="
            + String(accumulators)
            + " dimension="
            + String(dimension)
            + " ns="
            + String(Float64(perf_counter_ns() - start) / 20000.0)
            + " checksum="
            + String(total)
        )


def main() raises:
    for dimension in [31, 64, 384, 768, 1536]:
        comptime for metric in range(2):
            bench[1, metric](dimension)
            bench[2, metric](dimension)
            bench[4, metric](dimension)
