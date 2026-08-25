from akasha.compute.distance import (
    cosine_similarity,
    dot_product,
    l2_squared_distance,
)
from std.testing import assert_almost_equal, assert_raises, TestSuite


def test_dot_product_returns_raw_score() raises:
    var lhs: List[Float32] = [1.0, 2.0, 3.0]
    var rhs: List[Float32] = [4.0, -1.0, 2.0]

    assert_almost_equal(dot_product(lhs, rhs), 8.0, atol=1.0e-6)


def test_l2_returns_squared_distance() raises:
    var lhs: List[Float32] = [1.0, 2.0, 3.0]
    var rhs: List[Float32] = [4.0, 2.0, -1.0]

    assert_almost_equal(l2_squared_distance(lhs, rhs), 25.0, atol=1.0e-6)


def test_cosine_returns_normalized_similarity() raises:
    var lhs: List[Float32] = [1.0, 0.0]
    var rhs: List[Float32] = [1.0, 1.0]

    assert_almost_equal(cosine_similarity(lhs, rhs), 0.70710677, atol=1.0e-6)


def test_distance_rejects_mismatched_dimensions() raises:
    var lhs: List[Float32] = [1.0, 2.0]
    var rhs: List[Float32] = [1.0]

    with assert_raises():
        _ = dot_product(lhs, rhs)


def test_distance_rejects_empty_vectors() raises:
    var lhs = List[Float32]()
    var rhs = List[Float32]()

    with assert_raises():
        _ = l2_squared_distance(lhs, rhs)


def test_cosine_rejects_zero_norm_vectors() raises:
    var lhs: List[Float32] = [0.0, 0.0]
    var rhs: List[Float32] = [1.0, 0.0]

    with assert_raises():
        _ = cosine_similarity(lhs, rhs)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
