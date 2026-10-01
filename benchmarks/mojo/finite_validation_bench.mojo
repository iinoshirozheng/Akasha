"""Compare finite-mask reduction placement without changing production code."""

from akasha.compute.distance import _validate_pair
from std.math import isfinite
from std.math import inf, nan
from std.sys import simd_width_of
from std.testing import assert_raises
from std.time import perf_counter_ns


@no_inline
def aggregate_mask(lhs: List[Float32], rhs: List[Float32]) raises:
    if len(lhs) == 0 or len(lhs) != len(rhs):
        raise Error("invalid dimensions")
    comptime width = simd_width_of[DType.float32]() * 4
    var valid = SIMD[DType.bool, width](fill=True)
    var offset = 0
    while offset + width <= len(lhs):
        var left = lhs.unsafe_ptr().unsafe_load[width=width](offset)
        var right = rhs.unsafe_ptr().unsafe_load[width=width](offset)
        valid &= isfinite(left) & isfinite(right)
        offset += width
    if not valid.reduce_and():
        raise Error("non-finite vector")
    while offset < len(lhs):
        if not isfinite(lhs[offset]) or not isfinite(rhs[offset]):
            raise Error("non-finite vector")
        offset += 1


@no_inline
def _validate[aggregate: Bool](lhs: List[Float32], rhs: List[Float32]) raises:
    comptime if aggregate:
        aggregate_mask(lhs, rhs)
    else:
        _validate_pair(lhs, rhs)


def measure[
    aggregate: Bool
](rows: List[List[Float32]], dimension: Int, sample: Int) raises:
    var checksum = Float32(0)
    var start = perf_counter_ns()
    for i in range(100000):
        _validate[aggregate](rows[0], rows[i % len(rows)])
        checksum += rows[i % len(rows)][0]
    var elapsed = perf_counter_ns() - start
    print(
        "aggregate=",
        aggregate,
        "dimension=",
        dimension,
        "sample=",
        sample,
        "ns=",
        Float64(elapsed) / 100000,
        "checksum=",
        checksum,
    )


def main() raises:
    for dimension in [1, 15, 16, 17, 31, 32, 63, 64, 65, 384, 1536]:
        var lhs = List[Float32](length=dimension, fill=1)
        var rhs = lhs.copy()
        for invalid in [
            nan[DType.float32](),
            inf[DType.float32](),
            -inf[DType.float32](),
        ]:
            for column in range(dimension):
                rhs[column] = invalid
                with assert_raises():
                    aggregate_mask(lhs, rhs)
                with assert_raises():
                    aggregate_mask(rhs, lhs)
                rhs[column] = 1
    for dimension in [31, 64, 384, 1536]:
        var rows = List[List[Float32]]()
        for row in range(32):
            var values = List[Float32]()
            for column in range(dimension):
                values.append(Float32((row * 11 + column * 7) % 31 - 15) / 16)
            rows.append(values^)
        for sample in range(7):
            if sample % 2 == 0:
                measure[False](rows, dimension, sample)
                measure[True](rows, dimension, sample)
            else:
                measure[True](rows, dimension, sample)
                measure[False](rows, dimension, sample)
