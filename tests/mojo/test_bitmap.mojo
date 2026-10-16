from akasha.index.bitmap import Bitmap, _word_count
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


def test_bitmap_materializes_only_set_ordinals_in_order() raises:
    var bitmap = Bitmap(140)
    bitmap.set(139)
    bitmap.set(1)
    bitmap.set(65)
    var ordinals = bitmap.set_ordinals()
    assert_equal(len(ordinals), 3)
    assert_equal(ordinals[0], 1)
    assert_equal(ordinals[1], 65)
    assert_equal(ordinals[2], 139)


def test_bitmap_word_boundaries_match_scalar_set_algebra() raises:
    var sizes: List[Int] = [0, 1, 63, 64, 65, 127, 128, 129, 257]
    for size in sizes:
        var full = Bitmap.full(size)
        var selected = Bitmap(size)
        var expected_count = 0
        for ordinal in range(size):
            if ordinal % 7 == 0 or ordinal % 64 == 63:
                selected.set(ordinal)
                expected_count += 1
        var intersection = full.intersection(selected)
        var union = full.union_with(selected)
        var difference = full.difference(selected)
        assert_equal(intersection.count(), expected_count)
        assert_equal(union.count(), size)
        assert_equal(difference.count(), size - expected_count)
        var included = intersection.set_ordinals()
        var excluded = difference.set_ordinals()
        var all = union.set_ordinals()
        assert_equal(len(included), expected_count)
        assert_equal(len(excluded), size - expected_count)
        assert_equal(len(all), size)
        var included_index = 0
        var excluded_index = 0
        for ordinal in range(size):
            assert_equal(all[ordinal], ordinal)
            var expected = ordinal % 7 == 0 or ordinal % 64 == 63
            assert_equal(intersection.contains(ordinal), expected)
            assert_equal(difference.contains(ordinal), not expected)
            if expected:
                assert_equal(included[included_index], ordinal)
                included_index += 1
            else:
                assert_equal(excluded[excluded_index], ordinal)
                excluded_index += 1
        # Growing a masked final word must not resurrect padding bits.
        full.resize(size + 65)
        for ordinal in range(size, size + 65):
            assert_false(full.contains(ordinal))
        full.set(size + 64)
        var grown = full.set_ordinals()
        assert_equal(full.count(), size + 1)
        assert_equal(len(grown), size + 1)
        assert_equal(grown[size], size + 64)


def test_bitmap_enumeration_skips_empty_words_and_clear_is_idempotent() raises:
    var bitmap = Bitmap(257)
    var expected: List[Int] = [0, 63, 64, 127, 128, 256]
    for ordinal in expected:
        bitmap.set(ordinal)
    assert_equal(bitmap.set_ordinals(), expected)
    var copied = bitmap.clone()
    for ordinal in expected:
        bitmap.clear(ordinal)
        bitmap.clear(ordinal)
    assert_equal(bitmap.count(), 0)
    assert_equal(len(bitmap.set_ordinals()), 0)
    assert_equal(copied.set_ordinals(), expected)


def test_bitmap_word_count_does_not_overflow_at_integer_limit() raises:
    # Exercise the size calculation without requesting an enormous allocation.
    # Both supported targets use 64-bit Int. Literal expectations avoid repeating
    # the production ceiling formula, including the first overflowing old input.
    var sizes: List[Int] = [
        0, 1, 63, 64, 65, Int.MAX - 64, Int.MAX - 63,
        Int.MAX - 62, Int.MAX - 1, Int.MAX,
    ]
    var expected: List[Int] = [
        0, 1, 1, 1, 2, 144_115_188_075_855_871, 144_115_188_075_855_871,
        144_115_188_075_855_872, 144_115_188_075_855_872, 144_115_188_075_855_872,
    ]
    for index in range(len(sizes)):
        assert_equal(_word_count(sizes[index]), expected[index])


def test_bitmap_contains_rejects_invalid_logical_bits_after_growth_and_clone() raises:
    var bitmap = Bitmap()
    for size in [0, 1, 63, 64, 65, 127, 128, 129, 257]:
        bitmap.resize(size)
        if size > 0:
            bitmap.set(size - 1)
        var copied = bitmap.clone()
        var before = bitmap.set_ordinals()
        # A physical final word may have padding, but padding is never public.
        for invalid in [Int.MIN, -1, size, size + 1, Int.MAX]:
            with assert_raises():
                _ = bitmap.contains(invalid)
            with assert_raises():
                _ = copied.contains(invalid)
        assert_equal(bitmap.set_ordinals(), before)
        assert_equal(copied.set_ordinals(), before)
        for ordinal in before:
            assert_true(bitmap.contains(ordinal))
            assert_true(copied.contains(ordinal))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
