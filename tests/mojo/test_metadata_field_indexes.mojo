from akasha.document.value import PayloadValue
from akasha.index.keyword import KeywordIndex
from akasha.index.sorted_block import SortedBlockIndex
from akasha.query.filter_ast import FilterCondition
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def test_keyword_index_evaluates_strict_string_and_bool_equality() raises:
    var index = KeywordIndex(5)
    index.add("category", PayloadValue.string("keep"), 0)
    index.add("category", PayloadValue.string("drop"), 1)
    index.add("category", PayloadValue.string("keep"), 2)
    index.add("active", PayloadValue.boolean(True), 2)
    index.add("active", PayloadValue.boolean(False), 3)

    var equal = index.evaluate(
        FilterCondition.equal("category", PayloadValue.string("keep"))
    )
    var not_equal = index.evaluate(
        FilterCondition.not_equal("category", PayloadValue.string("keep"))
    )
    var wrong_type = index.evaluate(
        FilterCondition.equal("category", PayloadValue.boolean(True))
    )

    assert_equal(equal.count(), 2)
    assert_true(equal.contains(0))
    assert_true(equal.contains(2))
    assert_equal(not_equal.count(), 1)
    assert_true(not_equal.contains(1))
    assert_equal(wrong_type.count(), 0)


def test_keyword_index_resize_and_remove_update_postings() raises:
    var index = KeywordIndex(1)
    index.add("active", PayloadValue.boolean(True), 0)
    index.resize(66)
    index.add("active", PayloadValue.boolean(True), 65)
    index.remove("active", PayloadValue.boolean(True), 0)
    var result = index.evaluate(
        FilterCondition.equal("active", PayloadValue.boolean(True))
    )
    assert_equal(result.size(), 66)
    assert_equal(result.count(), 1)
    assert_false(result.contains(0))
    assert_true(result.contains(65))


def test_sorted_block_evaluates_all_integer_ranges() raises:
    var index = SortedBlockIndex(6)
    index.add("page", PayloadValue.integer(10), 0)
    index.add("page", PayloadValue.integer(3), 1)
    index.add("page", PayloadValue.integer(7), 2)
    index.add("other", PayloadValue.integer(7), 3)
    index.add("page", PayloadValue.floating(7.0), 4)

    var equal = index.evaluate(
        FilterCondition.equal("page", PayloadValue.integer(7))
    )
    var not_equal = index.evaluate(
        FilterCondition.not_equal("page", PayloadValue.integer(7))
    )
    var less = index.evaluate(
        FilterCondition.less_than("page", PayloadValue.integer(7))
    )
    var less_equal = index.evaluate(
        FilterCondition.less_or_equal("page", PayloadValue.integer(7))
    )
    var greater = index.evaluate(
        FilterCondition.greater_than("page", PayloadValue.integer(7))
    )
    var greater_equal = index.evaluate(
        FilterCondition.greater_or_equal("page", PayloadValue.integer(7))
    )

    assert_equal(equal.count(), 1)
    assert_true(equal.contains(2))
    assert_equal(not_equal.count(), 2)
    assert_true(not_equal.contains(0))
    assert_true(not_equal.contains(1))
    assert_equal(less.count(), 1)
    assert_true(less.contains(1))
    assert_equal(less_equal.count(), 2)
    assert_equal(greater.count(), 1)
    assert_true(greater.contains(0))
    assert_equal(greater_equal.count(), 2)


def test_sorted_block_keeps_float_type_separate_and_supports_remove() raises:
    var index = SortedBlockIndex(4)
    index.add("score", PayloadValue.floating(1.5), 0)
    index.add("score", PayloadValue.floating(2.5), 1)
    index.add("score", PayloadValue.integer(2), 2)
    index.remove("score", PayloadValue.floating(1.5), 0)

    var floats = index.evaluate(
        FilterCondition.greater_or_equal("score", PayloadValue.floating(1.0))
    )
    var integers = index.evaluate(
        FilterCondition.greater_or_equal("score", PayloadValue.integer(1))
    )
    assert_equal(floats.count(), 1)
    assert_true(floats.contains(1))
    assert_equal(integers.count(), 1)
    assert_true(integers.contains(2))


def test_field_indexes_reject_wrong_value_families() raises:
    var keyword = KeywordIndex(1)
    var sorted = SortedBlockIndex(1)
    with assert_raises():
        keyword.add("page", PayloadValue.integer(1), 0)
    with assert_raises():
        sorted.add("category", PayloadValue.string("x"), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
