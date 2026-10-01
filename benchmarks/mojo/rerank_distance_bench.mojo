from akasha.compute.distance import _validate_pair
from akasha.compute.simd import _simd_dot_product_unchecked
from akasha.index.flat import authoritative_f32_score
from std.time import perf_counter_ns


@no_inline
def _score[mode: Int](lhs: List[Float32], rhs: List[Float32]) raises -> Float32:
    comptime if mode == 0:
        _validate_pair(lhs, rhs)
        return lhs[0]
    elif mode == 1:
        return _simd_dot_product_unchecked(lhs, rhs)
    else:
        return authoritative_f32_score(0, lhs, rhs)


def bench[mode: Int](dimension: Int) raises:
    var lhs = List[Float32]()
    var rows = List[List[Float32]]()
    for column in range(dimension):
        lhs.append(Float32(column % 17 - 8) / 8.0)
    for row in range(32):
        var values = List[Float32]()
        for column in range(dimension):
            values.append(Float32((row * 11 + column * 7) % 31 - 15) / 16.0)
        rows.append(values^)
    for sample in range(5):
        var checksum = Float32(0)
        var start = perf_counter_ns()
        for index in range(20000):
            checksum += _score[mode](lhs, rows[index % 32])
        print(
            "mode="
            + String(mode)
            + " dimension="
            + String(dimension)
            + " sample="
            + String(sample)
            + " ns="
            + String(Float64(perf_counter_ns() - start) / 20000.0)
            + " checksum="
            + String(checksum)
        )


def main() raises:
    for dimension in [31, 64, 384, 1536]:
        comptime for mode in range(3):
            bench[mode](dimension)
