from akasha.index.bitmap import Bitmap
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def test_bitmap_grows_sets_clears_and_counts_bits() raises:
    var bitmap = Bitmap(3)
    assert_equal(bitmap.size(), 3)
    assert_equal(bitmap.count(), 0)
    bitmap.set(0)
    bitmap.set(2)
    bitmap.set(2)
    assert_true(bitmap.contains(0))
    assert_false(bitmap.contains(1))
    assert_true(bitmap.contains(2))
    assert_equal(bitmap.count(), 2)

    bitmap.resize(130)
    bitmap.set(64)
    bitmap.set(129)
    bitmap.clear(2)
    bitmap.clear(2)
    assert_equal(bitmap.size(), 130)
    assert_equal(bitmap.count(), 3)
    assert_true(bitmap.contains(64))
    assert_true(bitmap.contains(129))


def test_bitmap_set_algebra_preserves_cardinality() raises:
    var left = Bitmap(70)
    left.set(1)
    left.set(2)
    left.set(65)
    var right = Bitmap(70)
    right.set(2)
    right.set(3)
    right.set(65)

    var intersection = left.intersection(right)
    var union = left.union_with(right)
    var difference = left.difference(right)

    assert_equal(intersection.count(), 2)
    assert_true(intersection.contains(2))
    assert_true(intersection.contains(65))
    assert_equal(union.count(), 4)
    assert_equal(difference.count(), 1)
    assert_true(difference.contains(1))


def test_bitmap_full_and_indexes_are_bounded() raises:
    var full = Bitmap.full(67)
    assert_equal(full.count(), 67)
    assert_true(full.contains(66))
    with assert_raises():
        full.set(67)
    with assert_raises():
        _ = full.contains(-1)

    var smaller = Bitmap(2)
    with assert_raises():
        _ = full.intersection(smaller)
    with assert_raises():
        full.resize(1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
