from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.index.metadata import MetadataIndex
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.query.index_evaluator import evaluate_all, evaluate_expression
from akasha.query.evaluator import matches_expression
from std.memory import bitcast
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


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


def test_metadata_bulk_load_preserves_slot_order_and_query_results() raises:
    var index = MetadataIndex()
    index.begin_bulk()
    for ordinal in range(1_000):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField(
                "path", PayloadValue.string("/item/" + String(ordinal))
            )
        )
        fields.append(
            DocumentField(
                "page", PayloadValue.integer(Int64((ordinal * 7919) % 1_000))
            )
        )
        index.upsert(10_000 + ordinal, fields^)
    index.finish_bulk()
    assert_equal(index.id_at(731), 10_731)
    var result = index.evaluate_condition(
        FilterCondition.equal("path", PayloadValue.string("/item/731"))
    )
    assert_equal(result.count(), 1)
    assert_true(index.contains_id(result, 10_731))


def test_bulk_and_incremental_cache_bytes_round_trip_after_mutations() raises:
    var bulk = MetadataIndex()
    var incremental = MetadataIndex()
    bulk.begin_bulk()
    for ordinal in range(96):
        var id = (ordinal * 53) % 96 - 48
        var value = "長字串-" * 20 + String(id % 4)
        var score = Float64(id % 5)
        if id % 7 == 0:
            score = -0.0
        bulk.upsert(id, _fields(value, Int64(id % 3), score, id % 2 == 0))
        incremental.upsert(
            id, _fields(value, Int64(id % 3), score, id % 2 == 0)
        )
    bulk.finish_bulk()
    var bulk_bytes = bulk.encode_cache_payload()
    var expected_bytes = incremental.encode_cache_payload()
    assert_equal(len(bulk_bytes), len(expected_bytes))
    for i in range(len(bulk_bytes)):
        assert_equal(bulk_bytes[i], expected_bytes[i])
    var restored = MetadataIndex.decode_cache_payload(bulk_bytes^)
    for id in range(-48, 48, 3):
        restored.delete(id)
        incremental.delete(id)
    for id in range(-48, 48, 6):
        restored.upsert(id, _fields("new", Int64.MIN, -0.0, True))
        incremental.upsert(id, _fields("new", Int64.MIN, -0.0, True))
    var actual_bytes = restored.encode_cache_payload()
    expected_bytes = incremental.encode_cache_payload()
    assert_equal(len(actual_bytes), len(expected_bytes))
    for i in range(len(actual_bytes)):
        assert_equal(actual_bytes[i], expected_bytes[i])
    for value in [Int64.MIN, Int64(-2), Int64(0), Int64(2), Int64.MAX]:
        for operator_kind in range(1, 7):
            var condition = FilterCondition(
                "page", UInt8(operator_kind), PayloadValue.integer(value)
            )
            var actual = restored.evaluate_condition(condition)
            var expected = incremental.evaluate_condition(condition)
            for ordinal in range(96):
                assert_equal(
                    actual.contains(ordinal), expected.contains(ordinal)
                )


def test_identical_payload_update_preserves_bytes_and_validates_input() raises:
    var index = MetadataIndex()
    index.upsert(7, _fields("same", Int64.MAX, -0.0, True))
    var before = index.encode_cache_payload()
    index.upsert(7, _fields("same", Int64.MAX, -0.0, True))
    var after = index.encode_cache_payload()
    assert_equal(before, after)
    var invalid = _fields("same", Int64.MAX, -0.0, True)
    invalid.append(DocumentField("category", PayloadValue.string("same")))
    with assert_raises():
        index.upsert(7, invalid^)
    assert_equal(index.encode_cache_payload(), before)
    var bulk = MetadataIndex()
    bulk.begin_bulk()
    bulk.upsert(7, _fields("same", Int64.MAX, -0.0, True))
    with assert_raises():
        bulk.upsert(7, _fields("same", Int64.MAX, -0.0, True))
    bulk.finish_bulk()


def test_payload_update_preserves_signed_zero_type_order_and_resurrection() raises:
    var index = MetadataIndex()
    index.upsert(7, _fields("same", 0, -0.0, True))
    index.upsert(7, _fields("same", 0, 0.0, True))
    assert_equal(
        bitcast[DType.uint64](index._fields[0][2].value.as_float()), UInt64(0)
    )
    index.upsert(7, [DocumentField("score", PayloadValue.integer(0))])
    assert_true(index._fields[0][0].value.is_integer())
    index.upsert(7, [DocumentField("score", PayloadValue.boolean(False))])
    assert_true(index._fields[0][0].value.is_boolean())
    index.upsert(7, [DocumentField("score", PayloadValue.string("0"))])
    assert_true(index._fields[0][0].value.is_string())
    var fields = _fields("same", 0, 0.0, True)
    fields.swap_elements(0, 3)
    index.upsert(7, fields^)
    assert_equal(index._fields[0][0].name, "active")
    index.delete(7)
    index.upsert(7, List[DocumentField]())
    assert_true(index.is_live_at(0))
    assert_equal(index.live_count(), 1)
    assert_equal(index.slot_count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
