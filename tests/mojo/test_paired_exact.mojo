from akasha.compute.simd import _prepared_pair_score as paired_score
from akasha.compute.simd import _prepare_f32_query, _prepared_score
from std.math import inf, nan
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def exercise[metric: Int]() raises:
    for size in [1, 3, 4, 15, 16, 17, 31, 63, 64, 65, 127, 128, 129, 384, 769, 1536]:
        var query = List[Float32]()
        for column in range(size):
            query.append(Float32((column * 7919 + 17) % 65521 - 32760) / 7919)
        var prepared = _prepare_f32_query(metric, query)
        for row in range(32):
            var first = List[Float32]()
            var second = List[Float32]()
            for column in range(size):
                var scale = Float32(1)
                if row % 3 == 0:
                    scale = 1.0e-9
                elif row % 3 == 1:
                    scale = 1.0e9
                first.append(Float32((row * 997 + column * 7919 + 19) % 65521 - 32760) / 7919 * scale)
                second.append(Float32((row * 993 + column * 7907 + 13) % 65521 - 32760) / 7919 * scale)
            var scores = paired_score[metric](query, first, second, prepared)
            assert_equal(bitcast[DType.uint32](scores[0]), bitcast[DType.uint32](_prepared_score[metric](query, first, prepared)))
            assert_equal(bitcast[DType.uint32](scores[1]), bitcast[DType.uint32](_prepared_score[metric](query, second, prepared)))
        for position in range(size):
            for bad in [inf[DType.float32](), -inf[DType.float32](), nan[DType.float32]()]:
                var values = query.copy()
                values[position] = bad
                with assert_raises(contains="finite"):
                    _ = paired_score[metric](query, values, query, prepared)
                with assert_raises(contains="finite"):
                    _ = paired_score[metric](query, query, values, prepared)
        var empty = List[Float32]()
        with assert_raises(contains="dimensions"):
            _ = paired_score[metric](query, empty, query, prepared)
        with assert_raises(contains="dimensions"):
            _ = paired_score[metric](query, query, empty, prepared)
        with assert_raises(contains="empty"):
            _ = paired_score[metric](empty, query, query, 0)
        var invalid = query.copy()
        invalid[0] = nan[DType.float32]()
        with assert_raises(contains="finite"):
            _ = paired_score[metric](query, invalid, empty, prepared)


def test_dot_pair_preserves_bits_and_each_candidate_check() raises:
    exercise[0]()


def test_l2_pair_preserves_bits_and_each_candidate_check() raises:
    exercise[1]()


def test_cosine_pair_preserves_bits_and_each_candidate_check() raises:
    exercise[2]()


def test_cosine_preserves_first_candidate_error_precedence() raises:
    for size in [3, 16, 17, 64, 65, 127]:
        var query = List[Float32](length=size, fill=1)
        var zeros = List[Float32](length=size, fill=0)
        var invalid = query.copy()
        invalid[size - 1] = nan[DType.float32]()
        var prepared = _prepare_f32_query(2, query)
        with assert_raises(contains="non-zero"):
            _ = paired_score[2](query, zeros, invalid, prepared)
        with assert_raises(contains="non-zero"):
            _ = paired_score[2](query, zeros, List[Float32](), prepared)
        with assert_raises(contains="finite"):
            _ = paired_score[2](query, invalid, zeros, prepared)
        with assert_raises(contains="non-zero"):
            _ = paired_score[2](query, query, zeros, prepared)
        with assert_raises(contains="non-zero"):
            _ = paired_score[2](zeros, query, invalid, 0)
        with assert_raises(contains="finite"):
            _ = paired_score[2](zeros, invalid, query, 0)


def test_finite_extremes_and_signed_zero_keep_score_bits() raises:
    for size in [3, 16, 17, 64, 65]:
        for value in [Float32(-0.0), Float32(0.0), Float32(1.0e30), Float32(-1.0e30)]:
            var query = List[Float32](length=size, fill=1)
            var first = List[Float32](length=size, fill=value)
            var second = first.copy()
            second[0] = Float32(1)
            comptime for metric in range(3):
                if metric == 2 and value == 0:
                    continue
                var prepared = _prepare_f32_query(metric, query)
                var scores = paired_score[metric](query, first, second, prepared)
                assert_equal(bitcast[DType.uint32](scores[0]), bitcast[DType.uint32](_prepared_score[metric](query, first, prepared)))
                assert_equal(bitcast[DType.uint32](scores[1]), bitcast[DType.uint32](_prepared_score[metric](query, second, prepared)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
