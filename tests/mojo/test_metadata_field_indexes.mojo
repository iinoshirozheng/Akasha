from akasha.document.value import PayloadValue
from akasha.index.keyword import KeywordIndex
from akasha.index.sorted_block import SortedBlockIndex
from akasha.query.filter_ast import FilterCondition
from std.memory import bitcast
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


def test_keyword_bulk_load_handles_high_cardinality_without_dense_postings() raises:
    var index = KeywordIndex(1_000)
    index.begin_bulk()
    for ordinal in range(1_000):
        index.add(
            "path", PayloadValue.string("/chunk/" + String(ordinal)), ordinal
        )
    index.finish_bulk()
    assert_equal(index.entry_count(), 1_000)
    var result = index.evaluate(
        FilterCondition.equal("path", PayloadValue.string("/chunk/731"))
    )
    assert_equal(result.count(), 1)
    assert_true(result.contains(731))
    index.resize(2_000)
    assert_equal(index.entry_count(), 1_000)


def test_sorted_block_bulk_load_sorts_unsorted_numeric_entries() raises:
    var index = SortedBlockIndex(1_000)
    index.begin_bulk()
    for ordinal in range(1_000):
        index.add(
            "page",
            PayloadValue.integer(Int64((ordinal * 7919) % 1_000)),
            ordinal,
        )
    index.finish_bulk()
    var result = index.evaluate(
        FilterCondition.greater_or_equal("page", PayloadValue.integer(990))
    )
    assert_equal(result.count(), 10)


def test_bulk_keyword_order_matches_incremental_with_type_and_ordinal_ties() raises:
    # Includes empty strings, UTF-8, heap-backed names/values and both value
    # families under the same field name. Reverse ordinals exercise the last key.
    var names: List[String] = ["", "same", "欄位", "field-" * 20]
    var values: List[String] = ["", "false", "值", "value-" * 40]
    var bulk = KeywordIndex(128)
    var incremental = KeywordIndex(128)
    bulk.begin_bulk()
    for ordinal in range(127, -1, -1):
        var name = names[(ordinal // 8) % len(names)]
        var value = PayloadValue.string(values[(ordinal // 2) % len(values)])
        if ordinal % 3 == 0:
            value = PayloadValue.boolean(ordinal % 2 == 0)
        bulk.add(name, value, ordinal)
        incremental.add(name, value, ordinal)
    bulk.finish_bulk()
    assert_equal(bulk.entry_count(), incremental.entry_count())
    for i in range(bulk.entry_count()):
        assert_equal(bulk._entries[i].name, incremental._entries[i].name)
        assert_equal(bulk._entries[i].kind, incremental._entries[i].kind)
        assert_equal(
            bulk._entries[i].string_value, incremental._entries[i].string_value
        )
        assert_equal(
            bulk._entries[i].bool_value, incremental._entries[i].bool_value
        )
        assert_equal(bulk._entries[i].ordinal, incremental._entries[i].ordinal)
    # Sorting must leave incremental add/remove and duplicate suppression valid.
    bulk.remove(names[0], PayloadValue.boolean(True), 0)
    bulk.add(names[0], PayloadValue.boolean(True), 0)
    bulk.add(names[0], PayloadValue.boolean(True), 0)
    assert_equal(bulk.entry_count(), 128)
    for name in names:
        if name == "":
            continue
        for text in values:
            for unequal in [False, True]:
                var condition = FilterCondition.equal(
                    name, PayloadValue.string(text)
                )
                if unequal:
                    condition = FilterCondition.not_equal(
                        name, PayloadValue.string(text)
                    )
                var actual = bulk.evaluate(condition)
                var expected = incremental.evaluate(condition)
                for ordinal in range(128):
                    assert_equal(
                        actual.contains(ordinal), expected.contains(ordinal)
                    )


def test_bulk_numeric_order_matches_incremental_at_extremes_and_signed_zero() raises:
    var names: List[String] = ["", "same", "欄位", "field-" * 20]
    var integers: List[Int64] = [Int64.MIN, -1, 0, 1, Int64.MAX]
    var floats: List[Float64] = [-1.0e300, -0.0, 0.0, 1.0e-300, 1.0e300]
    var bulk = SortedBlockIndex(160)
    var incremental = SortedBlockIndex(160)
    bulk.begin_bulk()
    for ordinal in range(159, -1, -1):
        var name = names[(ordinal // 10) % len(names)]
        var integer = PayloadValue.integer(
            integers[(ordinal // 2) % len(integers)]
        )
        var floating = PayloadValue.floating(
            floats[(ordinal // 2) % len(floats)]
        )
        bulk.add(name, integer, ordinal)
        bulk.add(name, floating, ordinal)
        incremental.add(name, integer, ordinal)
        incremental.add(name, floating, ordinal)
    bulk.finish_bulk()
    for i in range(160):
        assert_equal(bulk._integers[i].name, incremental._integers[i].name)
        assert_equal(bulk._integers[i].value, incremental._integers[i].value)
        assert_equal(
            bulk._integers[i].ordinal, incremental._integers[i].ordinal
        )
        assert_equal(bulk._floats[i].name, incremental._floats[i].name)
        assert_equal(
            bitcast[DType.uint64](bulk._floats[i].value),
            bitcast[DType.uint64](incremental._floats[i].value),
        )
        assert_equal(bulk._floats[i].ordinal, incremental._floats[i].ordinal)
    for name in names:
        if name == "":
            continue
        for operator_kind in range(1, 7):
            for value_index in range(5):
                var integer = FilterCondition(
                    name,
                    UInt8(operator_kind),
                    PayloadValue.integer(integers[value_index]),
                )
                var floating = FilterCondition(
                    name,
                    UInt8(operator_kind),
                    PayloadValue.floating(floats[value_index]),
                )
                var actual_int = bulk.evaluate(integer)
                var expected_int = incremental.evaluate(integer)
                var actual_float = bulk.evaluate(floating)
                var expected_float = incremental.evaluate(floating)
                for ordinal in range(160):
                    assert_equal(
                        actual_int.contains(ordinal),
                        expected_int.contains(ordinal),
                    )
                    assert_equal(
                        actual_float.contains(ordinal),
                        expected_float.contains(ordinal),
                    )


def test_bulk_empty_singleton_duplicates_and_state_validation() raises:
    for count in [0, 1, 2, 3, 31, 32, 33]:
        var keyword = KeywordIndex(max(count, 1))
        var numbers = SortedBlockIndex(max(count, 1))
        with assert_raises():
            keyword.finish_bulk()
        with assert_raises():
            numbers.finish_bulk()
        keyword.begin_bulk()
        numbers.begin_bulk()
        with assert_raises():
            keyword.begin_bulk()
        with assert_raises():
            numbers.begin_bulk()
        for _ in range(count):
            keyword.add("x", PayloadValue.string("same"), 0)
            numbers.add("x", PayloadValue.integer(0), 0)
            numbers.add("x", PayloadValue.floating(0.0), 0)
        with assert_raises():
            _ = keyword.evaluate(
                FilterCondition.equal("x", PayloadValue.string("same"))
            )
        with assert_raises():
            _ = numbers.evaluate(
                FilterCondition.equal("x", PayloadValue.integer(0))
            )
        keyword.finish_bulk()
        numbers.finish_bulk()
        assert_equal(keyword.entry_count(), count)
        assert_equal(len(numbers._integers), count)
        assert_equal(len(numbers._floats), count)
        assert_equal(
            keyword.evaluate(
                FilterCondition.equal("x", PayloadValue.string("same"))
            ).count(),
            1 if count else 0,
        )
        assert_equal(
            numbers.evaluate(
                FilterCondition.equal("x", PayloadValue.integer(0))
            ).count(),
            1 if count else 0,
        )
        assert_equal(
            numbers.evaluate(
                FilterCondition.equal("x", PayloadValue.floating(0.0))
            ).count(),
            1 if count else 0,
        )


def test_ordered_posting_updates_deduplicate_and_remove_boundary_ties() raises:
    var keywords = KeywordIndex(96)
    var numbers = SortedBlockIndex(96)
    for step in range(96):
        var ordinal = (step * 53) % 96
        var string_value = PayloadValue.string("字串" * 40 + String(ordinal % 3))
        var integer = PayloadValue.integer(Int64(ordinal % 3 - 1))
        var floating = PayloadValue.floating(-0.0 if ordinal % 2 == 0 else 0.0)
        keywords.add("key", string_value, ordinal)
        keywords.add("key", string_value, ordinal)
        numbers.add("key", integer, ordinal)
        numbers.add("key", integer, ordinal)
        numbers.add("key", floating, ordinal)
        numbers.add("key", PayloadValue.floating(0.0), ordinal)
    assert_equal(keywords.entry_count(), 96)
    assert_equal(len(numbers._integers), 96)
    assert_equal(len(numbers._floats), 96)
    for ordinal in range(96):
        if ordinal % 2 == 0:
            var string_value = PayloadValue.string(
                "字串" * 40 + String(ordinal % 3)
            )
            keywords.remove("key", string_value, ordinal)
            keywords.remove("key", string_value, ordinal)
            numbers.remove(
                "key", PayloadValue.integer(Int64(ordinal % 3 - 1)), ordinal
            )
            numbers.remove("key", PayloadValue.floating(0.0), ordinal)
    assert_equal(keywords.entry_count(), 48)
    assert_equal(len(numbers._integers), 48)
    assert_equal(len(numbers._floats), 48)
    var floats = numbers.evaluate(
        FilterCondition.equal("key", PayloadValue.floating(-0.0))
    )
    for ordinal in range(96):
        assert_equal(floats.contains(ordinal), ordinal % 2 != 0)
    for value in range(3):
        var strings = keywords.evaluate(
            FilterCondition.equal(
                "key", PayloadValue.string("字串" * 40 + String(value))
            )
        )
        var integers = numbers.evaluate(
            FilterCondition.equal("key", PayloadValue.integer(Int64(value - 1)))
        )
        for ordinal in range(96):
            var expected = ordinal % 2 != 0 and ordinal % 3 == value
            assert_equal(strings.contains(ordinal), expected)
            assert_equal(integers.contains(ordinal), expected)


def test_bulk_posting_removal_works_before_sorting() raises:
    var keywords = KeywordIndex(4)
    var numbers = SortedBlockIndex(4)
    keywords.begin_bulk()
    numbers.begin_bulk()
    for ordinal in [3, 1, 2, 0]:
        keywords.add("key", PayloadValue.boolean(True), ordinal)
        numbers.add("key", PayloadValue.integer(1), ordinal)
        numbers.add("key", PayloadValue.floating(1), ordinal)
    keywords.remove("key", PayloadValue.boolean(True), 1)
    numbers.remove("key", PayloadValue.integer(1), 1)
    numbers.remove("key", PayloadValue.floating(1), 1)
    keywords.finish_bulk()
    numbers.finish_bulk()
    var strings = keywords.evaluate(
        FilterCondition.equal("key", PayloadValue.boolean(True))
    )
    var integers = numbers.evaluate(
        FilterCondition.equal("key", PayloadValue.integer(1))
    )
    var floats = numbers.evaluate(
        FilterCondition.equal("key", PayloadValue.floating(1))
    )
    for ordinal in range(4):
        assert_equal(strings.contains(ordinal), ordinal != 1)
        assert_equal(integers.contains(ordinal), ordinal != 1)
        assert_equal(floats.contains(ordinal), ordinal != 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
