from akasha.document import PayloadValue
from akasha.query.filter_ast import FilterCondition
from std.math import inf
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def test_filter_condition_constructs_all_six_operators() raises:
    var equal = FilterCondition.equal(
        "category", PayloadValue.string("database")
    )
    var not_equal = FilterCondition.not_equal(
        "verified", PayloadValue.boolean(False)
    )
    var less = FilterCondition.less_than("page", PayloadValue.integer(10))
    var less_equal = FilterCondition.less_or_equal(
        "score", PayloadValue.floating(0.5)
    )
    var greater = FilterCondition.greater_than("page", PayloadValue.integer(2))
    var greater_equal = FilterCondition.greater_or_equal(
        "score", PayloadValue.floating(0.25)
    )

    assert_equal(equal.operator_kind(), FilterCondition.EQUAL)
    assert_equal(not_equal.operator_kind(), FilterCondition.NOT_EQUAL)
    assert_equal(less.operator_kind(), FilterCondition.LESS_THAN)
    assert_equal(less_equal.operator_kind(), FilterCondition.LESS_OR_EQUAL)
    assert_equal(greater.operator_kind(), FilterCondition.GREATER_THAN)
    assert_equal(
        greater_equal.operator_kind(), FilterCondition.GREATER_OR_EQUAL
    )
    assert_true(equal.value.is_string())
    assert_true(less.value.is_integer())
    assert_true(less_equal.value.is_floating())
    assert_true(not_equal.value.is_boolean())


def test_filter_condition_clone_is_owned() raises:
    var condition = FilterCondition.equal(
        "category", PayloadValue.string("database")
    )
    var cloned = condition.clone()

    condition.name = "changed"
    condition.value = PayloadValue.string("changed")

    assert_equal(cloned.name, "category")
    assert_equal(cloned.value.as_string(), "database")


def test_filter_condition_rejects_invalid_field_names_and_operator_tags() raises:
    with assert_raises():
        _ = FilterCondition.equal("", PayloadValue.integer(1))
    with assert_raises():
        _ = FilterCondition.equal("bad\0name", PayloadValue.integer(1))
    with assert_raises():
        _ = FilterCondition("page", UInt8(99), PayloadValue.integer(1))


def test_string_and_bool_filters_reject_range_operators() raises:
    with assert_raises():
        _ = FilterCondition.less_than("category", PayloadValue.string("z"))
    with assert_raises():
        _ = FilterCondition.greater_or_equal(
            "verified", PayloadValue.boolean(True)
        )

    var string_inequality = FilterCondition.not_equal(
        "category", PayloadValue.string("archive")
    )
    var bool_equality = FilterCondition.equal(
        "verified", PayloadValue.boolean(True)
    )
    assert_false(string_inequality.value.is_boolean())
    assert_true(bool_equality.value.is_boolean())


def test_filter_float_value_must_be_finite() raises:
    with assert_raises():
        _ = FilterCondition.equal(
            "score", PayloadValue.floating(inf[DType.float64]())
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
