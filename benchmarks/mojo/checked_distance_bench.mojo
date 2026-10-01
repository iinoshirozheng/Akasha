"""Prototype one-pass finite validation and existing F32 score arithmetic."""

from akasha.index.flat import authoritative_f32_score
from std.math import isfinite, sqrt, inf, nan
from std.memory import bitcast
from std.sys import simd_width_of
from std.testing import assert_equal, assert_raises
from std.time import perf_counter_ns


def fused_kernel[metric: Int, width: Int](lhs: List[Float32], rhs: List[Float32]) raises -> Float32:
    if len(lhs) == 0 or len(lhs) != len(rhs):
        raise Error("invalid dimensions")
    var total = SIMD[DType.float32, width](0)
    var left_norm = SIMD[DType.float32, width](0)
    var right_norm = SIMD[DType.float32, width](0)
    var valid = SIMD[DType.bool, width](fill=True)
    var offset = 0
    while offset + width <= len(lhs):
        var left = lhs.unsafe_ptr().unsafe_load[width=width](offset)
        var right = rhs.unsafe_ptr().unsafe_load[width=width](offset)
        valid &= isfinite(left) & isfinite(right)
        comptime if metric == 1:
            var difference = left - right
            total += difference * difference
        else:
            total += left * right
            comptime if metric == 2:
                left_norm += left * left
                right_norm += right * right
        offset += width
    if not valid.reduce_and():
        raise Error("vectors must contain only finite values")
    var score = total.reduce_add()
    var lhs_norm = left_norm.reduce_add()
    var rhs_norm = right_norm.reduce_add()
    while offset < len(lhs):
        var left = lhs[offset]
        var right = rhs[offset]
        if not isfinite(left) or not isfinite(right):
            raise Error("vectors must contain only finite values")
        comptime if metric == 1:
            var difference = left - right
            score += difference * difference
        else:
            score += left * right
            comptime if metric == 2:
                lhs_norm += left * left
                rhs_norm += right * right
        offset += 1
    comptime if metric == 2:
        if lhs_norm == 0 or rhs_norm == 0:
            raise Error("cosine similarity requires non-zero vectors")
        return score / sqrt(lhs_norm * rhs_norm)
    else:
        return score


@no_inline
def score[metric: Int, fused: Bool](lhs: List[Float32], rhs: List[Float32]) raises -> Float32:
    comptime if fused:
        comptime width = simd_width_of[DType.float32]()
        if len(lhs) >= 64:
            return fused_kernel[metric, width * 4](lhs, rhs)
        return fused_kernel[metric, width](lhs, rhs)
    else:
        return authoritative_f32_score(metric, lhs, rhs)


def measure[metric: Int, fused: Bool](rows: List[List[Float32]], dimension: Int, sample: Int) raises:
    var checksum = Float32(0)
    var start = perf_counter_ns()
    for i in range(20000):
        checksum += score[metric, fused](rows[0], rows[i % len(rows)])
    print("metric=", metric, "fused=", fused, "dimension=", dimension,
          "sample=", sample, "ns=", Float64(perf_counter_ns() - start) / 20000,
          "checksum=", checksum)


def main() raises:
    for dimension in [1, 3, 4, 15, 16, 17, 31, 63, 64, 65, 127, 384, 769, 1536]:
        var rows = List[List[Float32]]()
        for row in range(32):
            var values = List[Float32]()
            for column in range(dimension):
                values.append(Float32((row * 11 + column * 7) % 31 - 15) / 16)
            if dimension == 1 and values[0] == 0:
                values[0] = 1
            rows.append(values^)
        comptime for metric in range(3):
            for row in range(len(rows)):
                var current = score[metric, False](rows[0], rows[row])
                var fused = score[metric, True](rows[0], rows[row])
                assert_equal(bitcast[DType.uint32](current), bitcast[DType.uint32](fused))
        var rhs = rows[0].copy()
        for column in range(dimension):
            var old = rhs[column]
            for invalid in [nan[DType.float32](), inf[DType.float32](), -inf[DType.float32]()]:
                rhs[column] = invalid
                comptime for metric in range(3):
                    with assert_raises():
                        _ = score[metric, True](rows[0], rhs)
                    with assert_raises():
                        _ = score[metric, True](rhs, rows[0])
            rhs[column] = old
        if dimension in (31, 64, 384, 1536):
            comptime for metric in range(3):
                for sample in range(7):
                    if sample % 2 == 0:
                        measure[metric, False](rows, dimension, sample)
                        measure[metric, True](rows, dimension, sample)
                    else:
                        measure[metric, True](rows, dimension, sample)
                        measure[metric, False](rows, dimension, sample)
