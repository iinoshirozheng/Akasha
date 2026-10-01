from akasha.compute.distance import (
    cosine_similarity,
    dot_product,
    l2_squared_distance,
)
from akasha.compute.simd import (
    _prepare_f32_query,
    _prepared_f32_score,
    _simd_dot_product_unchecked,
    _simd_l2_squared_unchecked,
    prevalidated_simd_cosine_similarity,
    simd_cosine_similarity,
    simd_dot_product,
    simd_l2_squared_distance,
)
from std.math import inf, nan
from std.memory import bitcast
from std.sys import simd_width_of
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    TestSuite,
)


def _assert_matches_scalar(size: Int) raises:
    var lhs = List[Float32](capacity=size)
    var rhs = List[Float32](capacity=size)
    for i in range(size):
        lhs.append(Float32(i % 7) - 3.0)
        rhs.append(Float32((i * 3) % 11) - 5.0)

    assert_almost_equal(
        simd_dot_product(lhs, rhs),
        dot_product(lhs, rhs),
        atol=1.0e-4,
    )
    assert_almost_equal(
        _simd_dot_product_unchecked(lhs, rhs),
        simd_dot_product(lhs, rhs),
        atol=1.0e-4,
    )
    assert_almost_equal(
        simd_l2_squared_distance(lhs, rhs),
        l2_squared_distance(lhs, rhs),
        atol=1.0e-4,
    )
    assert_almost_equal(
        _simd_l2_squared_unchecked(lhs, rhs),
        simd_l2_squared_distance(lhs, rhs),
        atol=1.0e-4,
    )
    assert_almost_equal(
        simd_cosine_similarity(lhs, rhs),
        cosine_similarity(lhs, rhs),
        atol=1.0e-5,
    )


def test_simd_matches_scalar_below_hardware_width() raises:
    _assert_matches_scalar(3)


def test_simd_matches_scalar_at_hardware_width() raises:
    _assert_matches_scalar(simd_width_of[DType.float32]())


def test_simd_matches_scalar_with_tail() raises:
    _assert_matches_scalar(simd_width_of[DType.float32]() * 2 + 3)


def test_simd_rejects_invalid_vectors() raises:
    var lhs: List[Float32] = [1.0, inf[DType.float32]()]
    var rhs: List[Float32] = [1.0, 2.0]
    with assert_raises():
        _ = simd_dot_product(lhs, rhs)

    var mismatched: List[Float32] = [1.0]
    with assert_raises():
        _ = simd_l2_squared_distance(lhs, mismatched)


def test_four_register_accumulators_and_high_dimensional_tails() raises:
    for size in [64, 65, 127, 384, 769, 1536]:
        _assert_matches_scalar(size)


def test_finite_validation_checks_every_lane_and_scalar_tail() raises:
    for size in [3, 16, 17, 31, 63, 64, 65, 127]:
        var finite = List[Float32](length=size, fill=1.0)
        for position in range(size):
            for bad in [
                inf[DType.float32](),
                -inf[DType.float32](),
                nan[DType.float32](),
            ]:
                var values = finite.copy()
                values[position] = bad
                with assert_raises():
                    _ = simd_dot_product(values, finite)
                with assert_raises():
                    _ = simd_dot_product(finite, values)
                with assert_raises():
                    _ = simd_l2_squared_distance(values, finite)
                with assert_raises():
                    _ = simd_l2_squared_distance(finite, values)
                with assert_raises():
                    _ = simd_cosine_similarity(finite, values)
                with assert_raises():
                    _ = simd_cosine_similarity(values, finite)
        finite[size - 1] = Float32(1.0e-44)
        _ = simd_dot_product(finite, finite)
        _ = simd_l2_squared_distance(finite, finite)


def test_checked_scores_preserve_existing_accumulator_bits() raises:
    for size in [1, 3, 4, 15, 16, 17, 31, 63, 64, 65, 127, 384, 769, 1536]:
        var lhs = List[Float32]()
        for column in range(size):
            lhs.append(Float32((column * 7919) % 65521 - 32760) / 7919)
        for row in range(32):
            var rhs = List[Float32]()
            for column in range(size):
                var scale = Float32(1)
                if row % 3 == 0:
                    scale = 1.0e-9
                elif row % 3 == 1:
                    scale = 1.0e9
                rhs.append(
                    Float32((row * 997 + column * 7919) % 65521 - 32760)
                    / 7919
                    * scale
                )
            if size == 1 and rhs[0] == 0:
                rhs[0] = 1
            assert_equal(
                bitcast[DType.uint32](simd_dot_product(lhs, rhs)),
                bitcast[DType.uint32](_simd_dot_product_unchecked(lhs, rhs)),
            )
            assert_equal(
                bitcast[DType.uint32](simd_l2_squared_distance(lhs, rhs)),
                bitcast[DType.uint32](_simd_l2_squared_unchecked(lhs, rhs)),
            )
            assert_equal(
                bitcast[DType.uint32](simd_cosine_similarity(lhs, rhs)),
                bitcast[DType.uint32](
                    prevalidated_simd_cosine_similarity(lhs, rhs)
                ),
            )
        var zeros = List[Float32](length=size, fill=0)
        with assert_raises(contains="non-zero"):
            _ = simd_cosine_similarity(lhs, zeros)
        with assert_raises(contains="non-zero"):
            _ = simd_cosine_similarity(zeros, lhs)
    var empty = List[Float32]()
    with assert_raises(contains="empty"):
        _ = simd_cosine_similarity(empty, empty)


def test_prepared_scores_keep_bits_and_candidate_validation() raises:
    for size in [1, 3, 4, 15, 16, 17, 31, 63, 64, 65, 127, 128, 129, 384, 769, 1536]:
        var query = List[Float32]()
        for column in range(size):
            query.append(Float32((column * 7919 + 17) % 65521 - 32760) / 7919)
        for metric in range(3):
            var prepared = _prepare_f32_query(metric, query)
            for row in range(32):
                var candidate = List[Float32]()
                for column in range(size):
                    var scale: Float32 = 1.0
                    if row % 3 == 0:
                        scale = 1.0e-9
                    elif row % 3 == 1:
                        scale = 1.0e9
                    candidate.append(Float32((row * 997 + column * 7919 + 19) % 65521 - 32760) / 7919 * scale)
                var expected: Float32
                if metric == 0:
                    expected = simd_dot_product(query, candidate)
                elif metric == 1:
                    expected = simd_l2_squared_distance(query, candidate)
                else:
                    expected = simd_cosine_similarity(query, candidate)
                assert_equal(bitcast[DType.uint32](_prepared_f32_score(metric, query, candidate, prepared)), bitcast[DType.uint32](expected))
            for position in range(size):
                for bad in [inf[DType.float32](), -inf[DType.float32](), nan[DType.float32]()]:
                    var candidate = query.copy()
                    candidate[position] = bad
                    with assert_raises(contains="finite"):
                        _ = _prepared_f32_score(metric, query, candidate, prepared)
                    with assert_raises(contains="finite"):
                        _ = _prepare_f32_query(metric, candidate)
            with assert_raises(contains="match"):
                _ = _prepared_f32_score(metric, query, List[Float32](), prepared)
        var zero = List[Float32](length=size, fill=0)
        var zero_norm = _prepare_f32_query(2, zero)
        with assert_raises(contains="non-zero"):
            _ = _prepared_f32_score(2, zero, query, zero_norm)
        with assert_raises(contains="non-zero"):
            _ = _prepared_f32_score(2, query, zero, _prepare_f32_query(2, query))
    for metric in range(3):
        with assert_raises(contains="empty"):
            _ = _prepare_f32_query(metric, List[Float32]())


def test_prepared_scores_preserve_finite_extremes_and_signed_zero() raises:
    var extremes: List[Float32] = [
        0.0,
        -0.0,
        bitcast[DType.float32](UInt32(1)),
        bitcast[DType.float32](UInt32(0x80000001)),
        bitcast[DType.float32](UInt32(0x7F7FFFFF)),
        bitcast[DType.float32](UInt32(0xFF7FFFFF)),
        1.0,
        -1.0,
    ]
    for size in [1, 3, 16, 17, 64, 65, 1536]:
        for shift in range(len(extremes)):
            var query = List[Float32](length=size, fill=extremes[shift])
            var candidate = List[Float32]()
            for column in range(size):
                candidate.append(extremes[(column + shift) % len(extremes)])
            for metric in range(3):
                var norm = _prepare_f32_query(metric, query)
                var expected: Float32 = 0
                var rejected = False
                try:
                    if metric == 0:
                        expected = simd_dot_product(query, candidate)
                    elif metric == 1:
                        expected = simd_l2_squared_distance(query, candidate)
                    else:
                        expected = simd_cosine_similarity(query, candidate)
                except:
                    rejected = True
                if rejected:
                    with assert_raises(contains="non-zero"):
                        _ = _prepared_f32_score(metric, query, candidate, norm)
                else:
                    assert_equal(
                        bitcast[DType.uint32](
                            _prepared_f32_score(metric, query, candidate, norm)
                        ),
                        bitcast[DType.uint32](expected),
                    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
