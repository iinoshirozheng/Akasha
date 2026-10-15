from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.index.metadata import MetadataIndex
from akasha.query.evaluator import matches_all
from akasha.query.filter_ast import FilterCondition
from std.testing import assert_equal, TestSuite


def _fields(id: Int) raises -> List[DocumentField]:
    var value: PayloadValue
    if id == 1:
        value = PayloadValue.integer(2)
    elif id == 2:
        value = PayloadValue.floating(2.0)
    elif id == 3:
        value = PayloadValue.floating(2.5)
    elif id == 4:
        value = PayloadValue.integer(3)
    elif id == 5:
        value = PayloadValue.string("2")
    elif id == 6:
        value = PayloadValue.boolean(True)
    elif id == 7:
        return []
    else:
        value = PayloadValue.integer(9_007_199_254_740_993)
    return [DocumentField("x", value^)]


def _check(condition: FilterCondition, expected: List[Int]) raises:
    var index = MetadataIndex()
    for id in range(1, 9):
        index.upsert(id, _fields(id))
    var hits = index.evaluate_condition(condition)
    assert_equal(hits.count(), len(expected))
    for id in range(1, 9):
        var matches = False
        for wanted in expected:
            if id == wanted:
                matches = True
        assert_equal(index.contains_id(hits, id), matches)
        assert_equal(matches_all(_fields(id), [condition.clone()]), matches)


def test_match_except_uses_literal_type_and_excludes_missing() raises:
    _check(FilterCondition.not_equal("x", PayloadValue.string("2")), [1, 2, 3, 4, 6, 8])
    _check(FilterCondition.not_equal("x", PayloadValue.integer(2)), [2, 3, 4, 5, 6, 8])
    _check(FilterCondition.equal("x", PayloadValue.integer(2)), [1])
    _check(FilterCondition.not_equal("x", PayloadValue.boolean(True)), [])


def test_numeric_ranges_include_integer_and_float_payloads() raises:
    _check(FilterCondition.equal("x", PayloadValue.floating(2.0)), [1, 2])
    _check(FilterCondition.not_equal("x", PayloadValue.floating(2.0)), [3, 4, 8])
    _check(FilterCondition.less_or_equal("x", PayloadValue.integer(2)), [1, 2])
    _check(FilterCondition.greater_than("x", PayloadValue.integer(2)), [3, 4, 8])


def test_numeric_ranges_use_f64_while_integer_matches_remain_exact() raises:
    _check(FilterCondition.equal("x", PayloadValue.integer(9_007_199_254_740_992)), [])
    _check(FilterCondition.equal("x", PayloadValue.floating(9_007_199_254_740_992)), [8])
    _check(FilterCondition.greater_than("x", PayloadValue.integer(9_007_199_254_740_992)), [])
    _check(FilterCondition.less_or_equal("x", PayloadValue.integer(9_007_199_254_740_992)), [1, 2, 3, 4, 8])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
