from akasha.compute.simd import _prepare_f32_query, _prepared_score, _prepared_pair_score
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def exercise[metric: Int]() raises:
    for size in [4, 16, 17, 64, 65]:
        var query = List[Float32](length=size, fill=1)
        var prepared = _prepare_f32_query(metric, query)
        for exponent in range(256):
            for fraction in [0, 1, 0x400000, 0x7FFFFF]:
                for sign in [0, 0x80000000]:
                    var word = UInt32(sign) | (UInt32(exponent) << 23) | UInt32(fraction)
                    for position in range(size):
                        var first = query.copy()
                        first[position] = bitcast[DType.float32](word)
                        if exponent == 255:
                            with assert_raises(contains="finite"):
                                _ = _prepared_pair_score[metric](query, first, query, prepared)
                            with assert_raises(contains="finite"):
                                _ = _prepared_pair_score[metric](query, query, first, prepared)
                        else:
                            var expected = _prepared_score[metric](query, first, prepared)
                            var left = _prepared_pair_score[metric](query, first, query, prepared)
                            var right = _prepared_pair_score[metric](query, query, first, prepared)
                            assert_equal(bitcast[DType.uint32](left[0]), bitcast[DType.uint32](expected))
                            assert_equal(bitcast[DType.uint32](right[1]), bitcast[DType.uint32](expected))
                        assert_equal(bitcast[DType.uint32](first[position]), word)


def test_dot_all_exponents_signs_and_nan_classes() raises:
    exercise[0]()


def test_l2_all_exponents_signs_and_nan_classes() raises:
    exercise[1]()


def test_cosine_all_exponents_signs_and_nan_classes() raises:
    exercise[2]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
