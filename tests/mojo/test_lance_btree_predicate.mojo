from akasha.index.lance_btree_predicate import btree_leaf_truth, validate_btree_query, search_btree_leaf
from akasha.index.lance_bitmap import LanceBitmapQuery, LanceBitmapBound, LanceBitmapRow
from akasha.index.lance_scalar import LanceScalarKey
from std.python import Python
from test_lance_bitmap import _key, _query, _ids
from std.testing import assert_equal, assert_raises, TestSuite


def test_three_valued_leaf_predicates() raises:
    var null = LanceScalarKey.null(2)
    var one = LanceScalarKey.integer(1)
    var two = LanceScalarKey.integer(2)
    assert_equal(btree_leaf_truth(one, LanceBitmapQuery.equals(null.copy())), -1)
    assert_equal(btree_leaf_truth(null, LanceBitmapQuery.is_null()), 1)
    assert_equal(btree_leaf_truth(one, LanceBitmapQuery.is_in([null.copy(), one.copy()])), 1)
    assert_equal(btree_leaf_truth(two, LanceBitmapQuery.is_in([null.copy(), one.copy()])), -1)
    assert_equal(btree_leaf_truth(null, LanceBitmapQuery.is_in([])), 0)
    var unbounded = LanceBitmapQuery.range_of(LanceBitmapBound(), LanceBitmapBound())
    assert_equal(btree_leaf_truth(null, unbounded), 1)
    var range = LanceBitmapQuery.range_of(LanceBitmapBound(Optional(null.copy())), LanceBitmapBound(Optional(one.copy())))
    assert_equal(btree_leaf_truth(two, range), 0)
    assert_equal(btree_leaf_truth(one, range), -1)
    assert_equal(btree_leaf_truth(null, range), -1)
    with assert_raises():
        validate_btree_query(LanceBitmapQuery.equals(LanceScalarKey.boolean(True)), 2)
    with assert_raises():
        validate_btree_query(LanceBitmapQuery.full_text(), 2)


def test_total_float_order_leaf_predicates() raises:
    var negative_zero = LanceScalarKey.float_bits(0x8000000000000000)
    var positive_zero = LanceScalarKey.float_bits(0)
    var nan = LanceScalarKey.float_bits(0x7ff8000000000001)
    assert_equal(btree_leaf_truth(negative_zero, LanceBitmapQuery.equals(positive_zero.copy())), 0)
    assert_equal(btree_leaf_truth(nan, LanceBitmapQuery.equals(nan.copy())), 1)
    assert_equal(btree_leaf_truth(negative_zero, LanceBitmapQuery.range_of(LanceBitmapBound(), LanceBitmapBound(Optional(positive_zero.copy()), False))), 1)


def test_leaf_result_masks_and_all_shortcuts() raises:
    var rows: List[LanceBitmapRow] = [LanceBitmapRow(LanceScalarKey.null(2), 9), LanceBitmapRow(LanceScalarKey.integer(1), 7)]
    var query = LanceBitmapQuery.equals(LanceScalarKey.integer(1))
    var result = search_btree_leaf(rows, 2, query)
    assert_equal(result.selected_rows.values(), [UInt64(7)])
    assert_equal(result.nulls.values(), [UInt64(9)])
    var untracked = search_btree_leaf(rows, 2, query, track_nulls=False)
    assert_equal(untracked.nulls.count(), 0)
    var all = search_btree_leaf(rows, 2, query, all_rows=True)
    assert_equal(all.selected_rows.values(), [UInt64(7), UInt64(9)])
    assert_equal(all.nulls.values(), [UInt64(9)])
    var non_null = search_btree_leaf(rows, 2, query, all_rows=True, track_nulls=False)
    assert_equal(non_null.selected_rows.values(), [UInt64(7)])
    var unknown = search_btree_leaf(rows, 2, LanceBitmapQuery.equals(LanceScalarKey.null(2)))
    assert_equal(unknown.selected_rows.count(), 0)
    assert_equal(unknown.nulls.values(), [UInt64(7), UInt64(9)])


def test_original_datafusion_leaf_predicate_corpus() raises:
    var corpus = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/lance-btree-leaf/cases.json").read())
    for scenario in corpus:
        var target = UInt8(Int(py=scenario["type"]))
        var rows = List[LanceBitmapRow]()
        for i in range(len(scenario["values"])):
            rows.append(LanceBitmapRow(_key(scenario["values"][i], target), UInt64(i)))
        for entry in scenario["queries"]:
            var query = _query(entry["query"], target)
            for track in range(2):
                var actual = search_btree_leaf(rows, target, query, track_nulls=track == 1)
                var expected = entry["results"][track]
                assert_equal(actual.selected_rows.values(), _ids(expected["selected"]), String(py=entry["query"]))
                assert_equal(actual.nulls.values(), _ids(expected["nulls"]), String(py=entry["query"]))
    assert_equal(len(corpus), 16)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
