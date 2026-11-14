from akasha.index.lance_btree_lookup import LanceBTreeLookup, BTreePageStats, BTreePageMatch
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_bitmap import LanceBitmapBound
from akasha.query.control import CancellationToken, QueryControl
from std.python import Python
from test_lance_bitmap import _key, _bound as _fixture_bound
from std.testing import assert_equal, assert_raises, TestSuite


def _ids(values: List[BTreePageMatch]) -> List[Int]:
    var result = List[Int]()
    for value in values:
        result.append(value.page)
    return result^


def _all(values: List[BTreePageMatch]) -> List[Bool]:
    var result = List[Bool]()
    for value in values:
        result.append(value.all_rows)
    return result^


def _bound(value: Int64, included: Bool = True) raises -> LanceBitmapBound:
    return LanceBitmapBound(Optional(LanceScalarKey.integer(value)), included)


def test_original_lance_lookup_duplicate_minima_and_straddle_regression() raises:
    # Pinned btree.rs::test_btree_lookup_pages_between (Int32 lifted to Int64).
    var pages: List[BTreePageStats] = [
        BTreePageStats(LanceScalarKey.null(2), LanceScalarKey.integer(5), 2, 3),
        BTreePageStats(LanceScalarKey.integer(10), LanceScalarKey.integer(20), 0, 2),
        BTreePageStats(LanceScalarKey.integer(20), LanceScalarKey.integer(20), 0, 2),
        BTreePageStats(LanceScalarKey.integer(20), LanceScalarKey.integer(30), 0, 2),
        BTreePageStats(LanceScalarKey.integer(40), LanceScalarKey.integer(50), 0, 2)]
    var lookup = LanceBTreeLookup(2, pages^)
    assert_equal(lookup.search_start, 0)
    assert_equal(_ids(lookup.pages_eq(LanceScalarKey.integer(15))), [1])
    assert_equal(_ids(lookup.pages_eq(LanceScalarKey.integer(20))), [1, 2, 3])
    assert_equal(_ids(lookup.pages_eq(LanceScalarKey.integer(35))), List[Int]())
    var range = lookup.pages_between(_bound(20), _bound(25))
    assert_equal(_ids(range), [1, 2, 3])
    assert_equal(_all(range), [False, True, False])
    assert_equal(_ids(lookup.pages_between(_bound(0), _bound(5))), [0])
    assert_equal(_all(lookup.pages_between(_bound(40), LanceBitmapBound())), [True])
    assert_equal(_ids(lookup.pages_between(_bound(31), _bound(39))), List[Int]())
    assert_equal(_ids(lookup.pages_between(_bound(25), _bound(15))), List[Int]())
    assert_equal(_ids(lookup.pages_in([LanceScalarKey.integer(20), LanceScalarKey.integer(20), LanceScalarKey.null(2)])), [0, 1, 2, 3])


def test_null_pages_empty_bounds_controls_and_statistics_validation() raises:
    var pages: List[BTreePageStats] = [
        BTreePageStats(LanceScalarKey.null(2), LanceScalarKey.null(2), 2, 2),
        BTreePageStats(LanceScalarKey.null(2), LanceScalarKey.integer(5), 1, 2),
        BTreePageStats(LanceScalarKey.integer(5), LanceScalarKey.integer(5), 0, 2)]
    var lookup = LanceBTreeLookup(2, pages^)
    assert_equal(lookup.search_start, 1)
    assert_equal(_ids(lookup.pages_null()), [1, 0])
    assert_equal(_all(lookup.pages_null()), [False, True])
    assert_equal(_ids(lookup.pages_eq(LanceScalarKey.null(2))), [1, 0])
    assert_equal(_ids(lookup.pages_between(_bound(5, False), LanceBitmapBound())), List[Int]())
    assert_equal(_ids(lookup.pages_between(_bound(5), _bound(5, False))), [1, 2])
    var empty = LanceBTreeLookup(2, [])
    assert_equal(_ids(empty.pages_eq(LanceScalarKey.integer(0))), List[Int]())
    var token = CancellationToken()
    token.cancel()
    var control = Optional(QueryControl(token, max_candidates=10))
    with assert_raises(contains="cancel"):
        _ = empty.pages_in([], control)
    with assert_raises(contains="cancel"):
        _ = empty.pages_null(control)
    with assert_raises():
        _ = lookup.pages_eq(LanceScalarKey.boolean(True))
    with assert_raises():
        _ = LanceBTreeLookup(2, [BTreePageStats(LanceScalarKey.integer(9), LanceScalarKey.integer(1), 0, 2)])
    with assert_raises():
        _ = LanceBTreeLookup(2, [BTreePageStats(LanceScalarKey.null(2), LanceScalarKey.integer(1), 0, 2)])


def test_original_source_lookup_corpus() raises:
    var corpus = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/lance-btree-lookup/cases.json").read())
    var queries = 0
    for scenario in corpus:
        var target = UInt8(Int(py=scenario["type"]))
        var pages = List[BTreePageStats]()
        for page in scenario["pages"]:
            pages.append(BTreePageStats(_key(page[0], target), _key(page[1], target), Int(py=page[2]), Int(py=page[3])))
        var lookup = LanceBTreeLookup(target, pages^)
        for entry in scenario["queries"]:
            var query = entry["query"]
            var op = String(py=query["op"])
            var actual: List[BTreePageMatch]
            if op == "null":
                actual = lookup.pages_null()
            elif op == "eq":
                actual = lookup.pages_eq(_key(query["value"], target))
            elif op == "range":
                actual = lookup.pages_between(_fixture_bound(query["lower"], target), _fixture_bound(query["upper"], target))
            else:
                var values = List[LanceScalarKey]()
                for value in query["values"]:
                    values.append(_key(value, target))
                actual = lookup.pages_in(values)
            var expected = entry["matches"]
            assert_equal(len(actual), len(expected))
            for i in range(len(actual)):
                assert_equal(actual[i].page, Int(py=expected[i][0]))
                assert_equal(actual[i].all_rows, Bool(py=expected[i][1]))
            queries += 1
    assert_equal(len(corpus), 183)
    assert_equal(queries, 48720)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
