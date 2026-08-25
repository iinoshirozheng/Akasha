from akasha.compute.topk import BoundedTopK
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    TestSuite,
)


def test_larger_scores_replace_worst_entry() raises:
    var topk = BoundedTopK(2, smaller_is_better=False)
    topk.offer(10, 1.0)
    topk.offer(20, 3.0)
    topk.offer(30, 2.0)

    var results = topk.sorted_entries()
    assert_equal(len(results), 2)
    assert_equal(results[0].id, 20)
    assert_almost_equal(results[0].score, 3.0, atol=1.0e-6)
    assert_equal(results[1].id, 30)


def test_smaller_scores_are_ordered_first() raises:
    var topk = BoundedTopK(2, smaller_is_better=True)
    topk.offer(10, 4.0)
    topk.offer(20, 1.0)
    topk.offer(30, 2.0)

    var results = topk.sorted_entries()
    assert_equal(results[0].id, 20)
    assert_equal(results[1].id, 30)


def test_equal_scores_prefer_ascending_ids() raises:
    var topk = BoundedTopK(2, smaller_is_better=False)
    topk.offer(30, 5.0)
    topk.offer(10, 5.0)
    topk.offer(20, 5.0)

    var results = topk.sorted_entries()
    assert_equal(results[0].id, 10)
    assert_equal(results[1].id, 20)


def test_topk_rejects_non_positive_capacity() raises:
    with assert_raises():
        _ = BoundedTopK(0, smaller_is_better=False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
