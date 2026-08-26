from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.index.metadata import MetadataIndex
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.index_evaluator import evaluate_all, evaluate_expression
from akasha.query.evaluator import matches_expression
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def _fields(
    category: String, page: Int64, score: Float64, active: Bool
) raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("category", PayloadValue.string(category)))
    fields.append(DocumentField("page", PayloadValue.integer(page)))
    fields.append(DocumentField("score", PayloadValue.floating(score)))
    fields.append(DocumentField("active", PayloadValue.boolean(active)))
    return fields^


def _condition(var condition: FilterCondition) raises -> FilterExpression:
    return FilterExpression.condition(condition^)


def test_metadata_index_assigns_stable_ordinals_and_evaluates_conditions() raises:
    var index = MetadataIndex()
    index.upsert(30, _fields("keep", 3, 0.5, True))
    index.upsert(10, _fields("drop", 7, 1.5, False))
    index.upsert(20, _fields("keep", 9, 2.5, True))

    assert_equal(index.slot_count(), 3)
    assert_equal(index.live_count(), 3)
    assert_equal(index.id_at(0), 30)
    assert_equal(index.id_at(1), 10)
    assert_equal(index.id_at(2), 20)

    var category = index.evaluate_condition(
        FilterCondition.equal("category", PayloadValue.string("keep"))
    )
    var page = index.evaluate_condition(
        FilterCondition.greater_or_equal("page", PayloadValue.integer(7))
    )
    var score = index.evaluate_condition(
        FilterCondition.less_than("score", PayloadValue.floating(2.0))
    )
    assert_equal(category.count(), 2)
    assert_true(category.contains(0))
    assert_true(category.contains(2))
    assert_equal(page.count(), 2)
    assert_true(page.contains(1))
    assert_true(page.contains(2))
    assert_equal(score.count(), 2)
    assert_true(score.contains(0))
    assert_true(score.contains(1))


def test_indexed_boolean_evaluator_handles_nested_and_empty_nodes() raises:
    var index = MetadataIndex()
    index.upsert(1, _fields("keep", 1, 1.0, True))
    index.upsert(2, _fields("drop", 8, 2.0, True))
    index.upsert(3, _fields("drop", 2, 3.0, False))
    var any_children = List[FilterExpression]()
    any_children.append(
        _condition(
            FilterCondition.equal("category", PayloadValue.string("keep"))
        )
    )
    any_children.append(
        _condition(
            FilterCondition.greater_or_equal("page", PayloadValue.integer(5))
        )
    )
    var any = FilterExpression.any(any_children^)
    var expression = FilterExpression.negate(any^)
    var result = evaluate_expression(index, expression)
    assert_equal(result.count(), 1)
    assert_true(result.contains(2))

    var empty_all = evaluate_expression(
        index, FilterExpression.all(List[FilterExpression]())
    )
    var empty_any = evaluate_expression(
        index, FilterExpression.any(List[FilterExpression]())
    )
    assert_equal(empty_all.count(), 3)
    assert_equal(empty_any.count(), 0)


def test_index_preserves_missing_and_type_mismatch_semantics() raises:
    var index = MetadataIndex()
    var string_field = List[DocumentField]()
    string_field.append(
        DocumentField("value", PayloadValue.string("different"))
    )
    var integer_field = List[DocumentField]()
    integer_field.append(DocumentField("value", PayloadValue.integer(9)))
    index.upsert(1, string_field^)
    index.upsert(2, integer_field^)
    index.upsert(3, List[DocumentField]())

    var not_equal = index.evaluate_condition(
        FilterCondition.not_equal("value", PayloadValue.string("target"))
    )
    assert_equal(not_equal.count(), 1)
    assert_true(not_equal.contains(0))
    assert_false(not_equal.contains(1))
    assert_false(not_equal.contains(2))


def test_index_incrementally_replaces_deletes_and_reuses_ids() raises:
    var index = MetadataIndex()
    index.upsert(7, _fields("old", 1, 1.0, False))
    index.upsert(8, _fields("old", 1, 1.0, False))
    index.upsert(7, _fields("new", 2, 2.0, True))
    index.delete(8)
    index.delete(9)

    var old = index.evaluate_condition(
        FilterCondition.equal("category", PayloadValue.string("old"))
    )
    var new = index.evaluate_condition(
        FilterCondition.equal("category", PayloadValue.string("new"))
    )
    assert_equal(index.slot_count(), 3)
    assert_equal(index.live_count(), 1)
    assert_equal(old.count(), 0)
    assert_equal(new.count(), 1)
    assert_true(index.contains_id(new, 7))
    assert_false(index.contains_id(new, 8))

    index.upsert(8, _fields("new", 4, 4.0, True))
    var reused = index.evaluate_condition(
        FilterCondition.equal("category", PayloadValue.string("new"))
    )
    assert_equal(index.slot_count(), 3)
    assert_equal(index.live_count(), 2)
    assert_true(index.contains_id(reused, 8))


def test_evaluate_all_intersects_conditions() raises:
    var index = MetadataIndex()
    index.upsert(1, _fields("keep", 2, 1.0, True))
    index.upsert(2, _fields("keep", 8, 1.0, True))
    index.upsert(3, _fields("drop", 8, 1.0, True))
    var conditions = List[FilterCondition]()
    conditions.append(
        FilterCondition.equal("category", PayloadValue.string("keep"))
    )
    conditions.append(
        FilterCondition.greater_than("page", PayloadValue.integer(5))
    )
    var result = evaluate_all(index, conditions)
    assert_equal(result.count(), 1)
    assert_true(index.contains_id(result, 2))


def _assert_matches_linear(
    index: MetadataIndex, expression: FilterExpression
) raises:
    var candidates = evaluate_expression(index, expression)
    for ordinal in range(4):
        var fields: List[DocumentField]
        if ordinal == 0:
            fields = _fields("keep", 2, 1.0, True)
        elif ordinal == 1:
            fields = _fields("drop", 8, 2.0, False)
        elif ordinal == 2:
            fields = _fields("keep", 8, 3.0, True)
        else:
            fields = List[DocumentField]()
        assert_equal(
            candidates.contains(ordinal),
            matches_expression(fields, expression),
        )


def test_indexed_results_match_linear_oracle_for_every_operator() raises:
    var index = MetadataIndex()
    index.upsert(1, _fields("keep", 2, 1.0, True))
    index.upsert(2, _fields("drop", 8, 2.0, False))
    index.upsert(3, _fields("keep", 8, 3.0, True))
    index.upsert(4, List[DocumentField]())

    _assert_matches_linear(
        index,
        _condition(
            FilterCondition.equal("category", PayloadValue.string("keep"))
        ),
    )
    _assert_matches_linear(
        index,
        _condition(
            FilterCondition.not_equal("category", PayloadValue.string("keep"))
        ),
    )
    _assert_matches_linear(
        index,
        _condition(FilterCondition.less_than("page", PayloadValue.integer(8))),
    )
    _assert_matches_linear(
        index,
        _condition(
            FilterCondition.less_or_equal("page", PayloadValue.integer(8))
        ),
    )
    _assert_matches_linear(
        index,
        _condition(
            FilterCondition.greater_than("score", PayloadValue.floating(1.0))
        ),
    )
    _assert_matches_linear(
        index,
        _condition(
            FilterCondition.greater_or_equal(
                "score", PayloadValue.floating(2.0)
            )
        ),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
