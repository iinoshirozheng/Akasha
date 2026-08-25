from akasha.document import DocumentField, PayloadValue
from akasha.query.evaluator import matches_all
from akasha.query.filter_ast import FilterCondition
from std.testing import assert_false, assert_true, TestSuite


def _fields() raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("category", PayloadValue.string("database")))
    fields.append(DocumentField("page", PayloadValue.integer(7)))
    fields.append(DocumentField("score", PayloadValue.floating(0.75)))
    fields.append(DocumentField("verified", PayloadValue.boolean(True)))
    return fields^


def _matches(
    fields: List[DocumentField], var condition: FilterCondition
) raises -> Bool:
    var conditions = List[FilterCondition]()
    conditions.append(condition^)
    return matches_all(fields, conditions)


def test_evaluator_matches_string_and_bool_equality() raises:
    var fields = _fields()

    assert_true(
        _matches(
            fields,
            FilterCondition.equal("category", PayloadValue.string("database")),
        )
    )
    assert_true(
        _matches(
            fields,
            FilterCondition.not_equal(
                "category", PayloadValue.string("archive")
            ),
        )
    )
    assert_true(
        _matches(
            fields,
            FilterCondition.equal("verified", PayloadValue.boolean(True)),
        )
    )
    assert_false(
        _matches(
            fields,
            FilterCondition.not_equal("verified", PayloadValue.boolean(True)),
        )
    )


def test_evaluator_matches_all_integer_comparisons() raises:
    var fields = _fields()

    assert_true(
        _matches(fields, FilterCondition.equal("page", PayloadValue.integer(7)))
    )
    assert_true(
        _matches(
            fields,
            FilterCondition.not_equal("page", PayloadValue.integer(6)),
        )
    )
    assert_true(
        _matches(
            fields,
            FilterCondition.less_than("page", PayloadValue.integer(8)),
        )
    )
    assert_true(
        _matches(
            fields,
            FilterCondition.less_or_equal("page", PayloadValue.integer(7)),
        )
    )
    assert_true(
        _matches(
            fields,
            FilterCondition.greater_than("page", PayloadValue.integer(6)),
        )
    )
    assert_true(
        _matches(
            fields,
            FilterCondition.greater_or_equal("page", PayloadValue.integer(7)),
        )
    )


def test_evaluator_matches_float_comparisons_without_coercion() raises:
    var fields = _fields()

    assert_true(
        _matches(
            fields,
            FilterCondition.equal("score", PayloadValue.floating(0.75)),
        )
    )
    assert_true(
        _matches(
            fields,
            FilterCondition.greater_than("score", PayloadValue.floating(0.5)),
        )
    )
    assert_false(
        _matches(
            fields,
            FilterCondition.less_or_equal("score", PayloadValue.floating(0.5)),
        )
    )
    assert_false(
        _matches(
            fields,
            FilterCondition.equal("score", PayloadValue.integer(0)),
        )
    )


def test_evaluator_uses_short_circuit_and_and_empty_matches() raises:
    var fields = _fields()
    var empty = List[FilterCondition]()
    assert_true(matches_all(fields, empty))

    var conditions = List[FilterCondition]()
    conditions.append(
        FilterCondition.equal("category", PayloadValue.string("database"))
    )
    conditions.append(
        FilterCondition.greater_or_equal("page", PayloadValue.integer(8))
    )
    assert_false(matches_all(fields, conditions))


def test_missing_fields_and_type_mismatches_never_match() raises:
    var fields = _fields()

    assert_false(
        _matches(
            fields,
            FilterCondition.equal("missing", PayloadValue.string("value")),
        )
    )
    assert_false(
        _matches(
            fields,
            FilterCondition.not_equal("missing", PayloadValue.string("value")),
        )
    )
    assert_false(
        _matches(
            fields,
            FilterCondition.not_equal("page", PayloadValue.floating(7.0)),
        )
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
