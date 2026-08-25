from akasha.index.flat import FlatIndex
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    TestSuite,
)


def test_dot_search_orders_high_scores_first_with_stable_ties() raises:
    var index = FlatIndex(2)
    index.add(20, [1.0, 0.0])
    index.add(10, [1.0, 0.0])
    index.add(30, [0.0, 1.0])
    var query: List[Float32] = [1.0, 0.0]

    var results = index.search_dot(query, 3)

    assert_equal(results[0].id, 10)
    assert_equal(results[1].id, 20)
    assert_equal(results[2].id, 30)


def test_l2_search_orders_small_distances_first() raises:
    var index = FlatIndex(2)
    index.add(2, [2.0, 0.0])
    index.add(1, [1.0, 0.0])
    var query: List[Float32] = [0.0, 0.0]

    var results = index.search_l2(query, 2)

    assert_equal(results[0].id, 1)
    assert_almost_equal(results[0].score, 1.0, atol=1.0e-6)
    assert_equal(results[1].id, 2)
    assert_almost_equal(results[1].score, 4.0, atol=1.0e-6)


def test_cosine_search_uses_normalized_scores() raises:
    var index = FlatIndex(2)
    index.add(1, [10.0, 0.0])
    index.add(2, [1.0, 1.0])
    var query: List[Float32] = [1.0, 0.0]

    var results = index.search_cosine(query, 2)

    assert_equal(results[0].id, 1)
    assert_almost_equal(results[0].score, 1.0, atol=1.0e-6)
    assert_equal(results[1].id, 2)
    assert_almost_equal(results[1].score, 0.70710677, atol=1.0e-6)


def test_search_limits_results_to_k() raises:
    var index = FlatIndex(1)
    index.add(1, [1.0])
    index.add(2, [2.0])
    var query: List[Float32] = [1.0]

    var results = index.search_dot(query, 1)

    assert_equal(len(results), 1)
    assert_equal(results[0].id, 2)


def test_empty_index_returns_no_results() raises:
    var index = FlatIndex(2)
    var query: List[Float32] = [1.0, 0.0]

    var results = index.search_dot(query, 3)

    assert_equal(len(results), 0)


def test_index_rejects_non_positive_dimension() raises:
    with assert_raises():
        _ = FlatIndex(0)


def test_add_rejects_wrong_dimension() raises:
    var index = FlatIndex(2)

    with assert_raises():
        index.add(1, [1.0])


def test_search_rejects_non_positive_k() raises:
    var index = FlatIndex(1)
    var query: List[Float32] = [1.0]

    with assert_raises():
        _ = index.search_dot(query, 0)


def test_search_rejects_wrong_query_dimension() raises:
    var index = FlatIndex(2)
    var query: List[Float32] = [1.0]

    with assert_raises():
        _ = index.search_dot(query, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
