from akasha.compute.distance import (
    cosine_similarity,
    dot_product,
    l2_squared_distance,
)
from akasha.compute.simd import (
    simd_cosine_similarity,
    simd_dot_product,
    simd_dot_product_unchecked,
    simd_l2_squared_distance,
    simd_l2_squared_unchecked,
)
from std.math import inf
from std.sys import simd_width_of
from std.testing import assert_almost_equal, assert_raises, TestSuite


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
        simd_dot_product_unchecked(lhs, rhs),
        simd_dot_product(lhs, rhs),
        atol=1.0e-4,
    )
    assert_almost_equal(
        simd_l2_squared_distance(lhs, rhs),
        l2_squared_distance(lhs, rhs),
        atol=1.0e-4,
    )
    assert_almost_equal(
        simd_l2_squared_unchecked(lhs, rhs),
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
