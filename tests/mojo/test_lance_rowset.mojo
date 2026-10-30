from akasha.index.roaring_rows import RoaringRowSet
from akasha.index.nullable_rows import NullableRowSet, NullableRowMask
from akasha.query.control import CancellationToken, QueryControl
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite
from std.python import Python, PythonObject


def _ids(values: PythonObject) raises -> List[UInt64]:
    var result = List[UInt64]()
    for value in values:
        var id = UInt64(0)
        for byte in value.to_bytes(8, "big"):
            id = (id << 8) | UInt64(Int(py=byte))
        result.append(id)
    return result^


def _set(values: List[UInt64]) raises -> RoaringRowSet:
    var result = RoaringRowSet()
    for value in values:
        _ = result.insert(value)
    return result^


def test_sparse_dense_transitions_and_uint64_identity() raises:
    var rows = RoaringRowSet()
    for value in range(4097):
        assert_true(rows.insert(UInt64(value)))
    assert_equal(rows.count(), 4097)
    assert_false(rows.insert(UInt64(4096)))
    assert_true(rows.remove(UInt64(4096)))
    assert_false(rows.remove(UInt64(4096)))
    for value in [UInt64(65536), UInt64(1)<<32, UInt64(1)<<63, UInt64.MAX]:
        assert_true(rows.insert(value))
        assert_true(rows.contains(value))
    var copy = rows.copy()
    assert_true(rows.remove(UInt64.MAX))
    assert_true(copy.contains(UInt64.MAX))
    assert_equal(copy.values()[copy.count()-1], UInt64.MAX)


def test_bounded_mutation_and_cancellation() raises:
    var singleton: List[UInt64] = [1]
    var rows = RoaringRowSet(max_values=1)
    assert_true(rows.insert(1))
    assert_false(rows.insert(1))
    with assert_raises():
        _ = rows.insert(2)
    assert_equal(rows.values(), singleton)
    var small = RoaringRowSet(max_bytes=1)
    with assert_raises():
        _ = small.insert(UInt64.MAX)
    assert_equal(small.count(), 0)
    with assert_raises():
        _ = rows.union_with(_set([2]))
    assert_equal(rows.values(), singleton)
    with assert_raises():
        _ = rows.values(max_bytes=7)
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=100)
    token.cancel()
    with assert_raises():
        _ = rows.union_with(rows, control=Optional(control.copy()))
    with assert_raises():
        _ = rows.values(control=Optional(control.copy()))


def test_unknown_rows_survive_negation_and_boolean_composition() raises:
    var a = NullableRowMask(NullableRowSet(_set([1]), _set([2])), False)
    var inverse = a.negated()
    assert_true(inverse.selected(0))
    assert_false(inverse.selected(1))
    assert_false(inverse.selected(2))
    var b = NullableRowMask(NullableRowSet(_set([2]), _set([])), False)
    var either = a.or_with(b)
    assert_true(either.selected(2))
    assert_false(either.rows.nulls.contains(2))
    var neither = a.and_with(b)
    assert_false(neither.selected(2))
    assert_true(neither.rows.nulls.contains(2))


def test_original_roaring_sets_and_mutations() raises:
    var builtins = Python.import_module("builtins")
    var corpus = Python.import_module("json").loads(builtins.open("tests/fixtures/lance-rowset/cases.json").read())
    for row in corpus["sets"]:
        var a = RoaringRowSet()
        var input = _ids(row["a"])
        for i in range(len(input)):
            assert_equal(a.insert(input[i]), Bool(py=row["results"]["inserted"][i]))
        var b = _set(_ids(row["b"]))
        var expected = row["results"]["ops"]
        _same_set(a.union_with(b), expected["union"])
        _same_set(a.intersection(b), expected["intersection"])
        _same_set(a.difference(b), expected["difference"])
        _same_set(a.symmetric_difference(b), expected["xor"])
        var remove = _ids(row["remove"])
        for i in range(len(remove)):
            assert_equal(a.remove(remove[i]), Bool(py=row["results"]["removed"][i]))
        assert_equal(a.values(), _ids(row["results"]["after"]))
        assert_equal(a.count(), len(row["results"]["after"]))
        for id in a.values():
            assert_true(a.contains(id))
    assert_equal(len(corpus["sets"]), 309)


def _same_set(actual: RoaringRowSet, expected: PythonObject) raises:
    assert_equal(actual.values(), _ids(expected))
    assert_equal(actual.count(), len(expected))


def _mask(value: PythonObject) raises -> NullableRowMask:
    return NullableRowMask(NullableRowSet(_set(_ids(value["selected"])), _set(_ids(value["nulls"]))), Bool(py=value["block"]))


def _same_mask(mask: NullableRowMask, expected: PythonObject, probe: List[UInt64]) raises:
    assert_equal(mask.block, Bool(py=expected["block"]))
    assert_equal(mask.rows.selected_rows.values(), _ids(expected["selected"]))
    assert_equal(mask.rows.nulls.values(), _ids(expected["nulls"]))
    for i in range(len(probe)):
        var state = 2 if mask.rows.nulls.contains(probe[i]) else 1 if mask.selected(probe[i]) else 0
        assert_equal(state, Int(py=expected["states"][i]))


def test_original_lance_nullable_formulas() raises:
    var builtins = Python.import_module("builtins")
    var corpus = Python.import_module("json").loads(builtins.open("tests/fixtures/lance-rowset/cases.json").read())
    for row in corpus["masks"]:
        var a = _mask(row["a"])
        var b = _mask(row["b"])
        var probe = _ids(row["probe"])
        var expected = row["results"]
        _same_mask(a.and_with(b), expected["and"], probe)
        _same_mask(a.or_with(b), expected["or"], probe)
        _same_mask(a.negated(), expected["not"], probe)
        var united = NullableRowSet.union_all([a.rows.copy(), b.rows.copy()])
        _same_mask(NullableRowMask(united^, False), expected["union_all"], probe)
    assert_equal(len(corpus["masks"]), 564)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
