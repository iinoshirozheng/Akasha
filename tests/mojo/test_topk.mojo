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


def test_float64_scores_preserve_binary_counts_and_large_native_distances() raises:
    var smaller = BoundedTopK[DType.float64](2, smaller_is_better=True)
    smaller.offer(1, Float64(16_777_217))
    smaller.offer(2, Float64(16_777_216))
    smaller.offer(3, Float64(16_777_218))
    var small = smaller.sorted_entries()
    assert_equal(small[0].id, 2)
    assert_equal(small[1].id, 1)
    assert_equal(small[1].score, Float64(16_777_217))
    var larger = BoundedTopK[DType.float64](2, smaller_is_better=False)
    larger.offer(3, Float64(1.0e100))
    larger.offer(2, Float64(1.0e101))
    larger.offer(-1, Float64(1.0e101))
    var large = larger.sorted_entries()
    assert_equal(large[0].id, -1)
    assert_equal(large[1].id, 2)
    assert_equal(large[0].score, Float64(1.0e101))
