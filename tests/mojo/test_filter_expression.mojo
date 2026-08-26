from akasha.document import PayloadValue
from akasha.query.filter_ast import FilterCondition, FilterExpression
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _leaf(name: String, value: Int64) raises -> FilterExpression:
    return FilterExpression.condition(
        FilterCondition.equal(name, PayloadValue.integer(value))
    )


def test_expression_constructs_condition_all_any_and_negate() raises:
    var condition = _leaf("page", 7)
    var all_children = List[FilterExpression]()
    all_children.append(_leaf("page", 7))
    all_children.append(_leaf("year", 2026))
    var all_expression = FilterExpression.all(all_children^)
    var any_expression = FilterExpression.any(List[FilterExpression]())
    var negated = FilterExpression.negate(_leaf("archived", 1))

    assert_equal(condition.kind(), FilterExpression.CONDITION)
    assert_equal(all_expression.kind(), FilterExpression.ALL)
    assert_equal(all_expression.child_count(), 2)
    assert_equal(any_expression.kind(), FilterExpression.ANY)
    assert_equal(any_expression.child_count(), 0)
    assert_equal(negated.kind(), FilterExpression.NEGATE)
    assert_equal(negated.child_count(), 1)
    assert_true(Bool(condition.get_condition()))
    assert_false(Bool(all_expression.get_condition()))


def test_expression_clone_preserves_nested_nodes() raises:
    var children = List[FilterExpression]()
    children.append(_leaf("page", 7))
    var expression = FilterExpression.all(children^)
    var cloned = expression.clone()

    assert_equal(expression.child_count(), 1)
    assert_equal(cloned.child_count(), 1)
    assert_equal(cloned.node_count(), expression.node_count())
    assert_equal(
        cloned.get_child_condition(0).value().name,
        "page",
    )


def test_expression_rejects_malformed_raw_shapes() raises:
    var no_condition = Optional[FilterCondition]()
    with assert_raises():
        _ = FilterExpression(UInt8(99), no_condition^, List[FilterExpression]())

    var condition = FilterCondition.equal("page", PayloadValue.integer(7))
    var optional_condition = Optional(condition^)
    var unexpected_child = List[FilterExpression]()
    unexpected_child.append(_leaf("year", 2026))
    with assert_raises():
        _ = FilterExpression(
            FilterExpression.CONDITION,
            optional_condition^,
            unexpected_child^,
        )

    var too_many = List[FilterExpression]()
    too_many.append(_leaf("page", 1))
    too_many.append(_leaf("page", 2))
    var no_negate_condition = Optional[FilterCondition]()
    with assert_raises():
        _ = FilterExpression(
            FilterExpression.NEGATE,
            no_negate_condition^,
            too_many^,
        )


def test_expression_enforces_maximum_depth() raises:
    var expression = _leaf("page", 7)
    for _ in range(FilterExpression.MAX_DEPTH - 1):
        expression = FilterExpression.negate(expression^)
    assert_equal(expression.depth(), FilterExpression.MAX_DEPTH)

    with assert_raises():
        _ = FilterExpression.negate(expression^)


def test_expression_enforces_maximum_node_count() raises:
    var accepted = List[FilterExpression]()
    for index in range(FilterExpression.MAX_NODES - 1):
        accepted.append(_leaf("field" + String(index), Int64(index)))
    var accepted_expression = FilterExpression.all(accepted^)
    assert_equal(accepted_expression.node_count(), FilterExpression.MAX_NODES)

    var rejected = List[FilterExpression]()
    for index in range(FilterExpression.MAX_NODES):
        rejected.append(_leaf("field" + String(index), Int64(index)))
    with assert_raises():
        _ = FilterExpression.all(rejected^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
