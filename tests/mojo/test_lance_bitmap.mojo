from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_bitmap import LanceBitmapIndex, LanceBitmapRow, LanceBitmapQuery, LanceBitmapBound, LanceOldRows
from akasha.index.roaring_rows import RoaringRowSet
from akasha.index.lance_json_input import extract_json_index_batch, infer_json_index_type, convert_json_index_batch
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_reader import parse_jsonb
from akasha.document.lance_json_result import LanceJsonResult
from akasha.query.control import CancellationToken, QueryControl
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite


def _u64(value: PythonObject) raises -> UInt64:
    var result = UInt64(0)
    for byte in value.to_bytes(8, "big"):
        result = (result << 8) | UInt64(Int(py=byte))
    return result


def _ids(values: PythonObject) raises -> List[UInt64]:
    var result = List[UInt64]()
    for value in values:
        result.append(_u64(value))
    return result^


def _key(value: PythonObject, target: UInt8) raises -> LanceScalarKey:
    if Bool(py=value == Python.none()):
        return LanceScalarKey.null(target)
    if target == 1:
        return LanceScalarKey.boolean(Bool(py=value))
    if target == 2:
        return LanceScalarKey.integer(Int64(Int(py=value)))
    if target == 3:
        return LanceScalarKey.float_bits(_u64(Python.import_module("builtins").int(value, 16)))
    if target == 4:
        return LanceScalarKey.text(String(py=value))
    var bytes = List[UInt8]()
    for byte in Python.import_module("builtins").bytes.fromhex(value):
        bytes.append(UInt8(Int(py=byte)))
    return LanceScalarKey.binary(bytes^)


def _rows(values: PythonObject, target: UInt8) raises -> List[LanceBitmapRow]:
    var result = List[LanceBitmapRow]()
    for value in values:
        result.append(LanceBitmapRow(_key(value["value"], target), _u64(value["id"])))
    return result^


def _bound(value: PythonObject, target: UInt8) raises -> LanceBitmapBound:
    if Bool(py=value == Python.none()):
        return LanceBitmapBound()
    return LanceBitmapBound(Optional(_key(value["value"], target)), Bool(py=value["included"]))


def _query(value: PythonObject, target: UInt8) raises -> LanceBitmapQuery:
    var op = String(py=value["op"])
    if op == "eq":
        return LanceBitmapQuery.equals(_key(value["value"], target))
    if op == "null":
        return LanceBitmapQuery.is_null()
    if op == "text":
        return LanceBitmapQuery.full_text()
    if op == "prefix":
        return LanceBitmapQuery.like_prefix(_key(value["value"], target))
    if op == "range":
        return LanceBitmapQuery.range_of(_bound(value["lower"], target), _bound(value["upper"], target))
    var values = List[LanceScalarKey]()
    for item in value["values"]:
        values.append(_key(item, target))
    return LanceBitmapQuery.is_in(values^)


def _check_index(index: LanceBitmapIndex, state: PythonObject, queries: PythonObject,
                 searches: PythonObject) raises:
    assert_equal(index.null_rows().values(), _ids(state[0]["rows"]))
    var keys = index.keys()
    assert_equal(len(keys), len(state)-1)
    for i in range(len(keys)):
        assert_equal(keys[i].compare(_key(state[i+1]["key"], index.target)), 0)
        assert_equal(index.lookup(keys[i]).values(), _ids(state[i+1]["rows"]))
    for i in range(len(queries)):
        var query = _query(queries[i], index.target)
        for track in range(2):
            var expected = searches[i*2+track]
            if Bool(py=expected.__contains__("error")):
                var rejected = False
                try:
                    _ = index.search(query, track_nulls=track == 0)
                except error:
                    assert_equal(String(error), String(py=expected["error"]))
                    rejected = True
                assert_true(rejected)
                continue
            var actual = index.search(query, track_nulls=track == 0)
            assert_equal(actual.selected_rows.values(), _ids(expected["selected"]))
            assert_equal(actual.nulls.values(), _ids(expected["nulls"]))


def test_original_lance_bitmap_train_search_merge_remap() raises:
    var builtins = Python.import_module("builtins")
    var corpus = Python.import_module("json").loads(builtins.open("tests/fixtures/lance-bitmap/cases.json").read())
    for row in corpus:
        var target = UInt8(Int(py=row["type"]))
        var index = LanceBitmapIndex.build(target, _rows(row["old"], target))
        var old_filter = Optional[LanceOldRows]()
        if not Bool(py=row["filter"] == Python.none()):
            var by_rows = Bool(py=row["filter"].__contains__("rows"))
            var filter_ids = _ids(row["filter"]["rows" if by_rows else "fragments"])
            old_filter = Optional(LanceOldRows(filter_ids^, fragments=not by_rows))
        var updated = index.updated(_rows(row["new"], target), old_filter=old_filter^)
        var mapping = Dict[UInt64, Optional[UInt64]]()
        for entry in row["mapping"].items():
            var old_id = _u64(builtins.int(entry[0]))
            mapping[old_id] = None if Bool(py=entry[1] == Python.none()) else Optional(_u64(entry[1]))
        var remapped = updated.remapped(mapping)
        var expected = row["results"]
        _check_index(index, expected["old_state"], row["queries"], expected["old_search"])
        _check_index(updated, expected["new_state"], row["queries"], expected["new_search"])
        _check_index(remapped, expected["remap_state"], row["queries"], expected["remap_search"])
        var domain = row["values"]
        for i in range(len(domain)):
            for j in range(len(domain)):
                var cmp = _key(domain[i], target).compare(_key(domain[j], target))
                assert_equal(cmp, Int(py=expected["comparisons"][i*len(domain)+j][0]))
                assert_equal(cmp == 0, Bool(py=expected["comparisons"][i*len(domain)+j][1]))
    assert_equal(len(corpus), 61)


def test_batches_nulls_empty_postings_and_owned_updates() raises:
    var old = LanceBitmapIndex.build(2, [LanceBitmapRow(LanceScalarKey.integer(1), 1)])
    var batches: List[List[LanceBitmapRow]] = [
        [LanceBitmapRow(LanceScalarKey.null(2), 3)], [],
        [LanceBitmapRow(LanceScalarKey.integer(2), 4)],
        [LanceBitmapRow(LanceScalarKey.integer(2), 5)],
    ]
    var updated = old.merge_sorted(batches, old_filter=Optional(LanceOldRows([])))
    assert_equal(len(updated.keys()), 2)  # upstream retains the emptied old key
    assert_equal(updated.lookup(LanceScalarKey.integer(1)).count(), 0)
    assert_equal(old.lookup(LanceScalarKey.integer(1)).count(), 1)
    batches.clear()
    assert_equal(updated.lookup(LanceScalarKey.integer(2)).count(), 2)
    var selected = updated.search(LanceBitmapQuery.equals(LanceScalarKey.integer(2)))
    assert_true(selected.nulls.contains(3))
    assert_equal(updated.search(LanceBitmapQuery.equals(LanceScalarKey.null(2))).nulls.count(), 0)
    var copy = updated.copy()
    var removed = updated.remapped({UInt64(4): Optional[UInt64](), UInt64(5): Optional[UInt64]()})
    assert_equal(removed.lookup(LanceScalarKey.integer(2)).count(), 0)
    assert_equal(copy.lookup(LanceScalarKey.integer(2)).count(), 2)


def test_limits_types_order_and_controls_fail_without_mutation() raises:
    var rows: List[LanceBitmapRow] = [LanceBitmapRow(LanceScalarKey.integer(1), 1), LanceBitmapRow(LanceScalarKey.integer(2), 2)]
    var index = LanceBitmapIndex.build(2, rows, max_rows=2)
    with assert_raises():
        _ = index.updated([LanceBitmapRow(LanceScalarKey.integer(3), 3)])
    assert_equal(len(index.keys()), 2)
    with assert_raises():
        _ = LanceBitmapIndex.build(2, rows, max_bytes=1)
    with assert_raises():
        _ = index.merge_sorted([[rows[1].copy()], [rows[0].copy()]])
    with assert_raises():
        _ = LanceScalarKey.integer(1).compare(LanceScalarKey.boolean(True))
    with assert_raises():
        _ = index.updated([LanceBitmapRow(LanceScalarKey.boolean(True), 0)])
    with assert_raises():
        _ = index.search(LanceBitmapQuery.equals(LanceScalarKey.boolean(True)))
    with assert_raises():
        _ = LanceOldRows([UInt64.MAX], fragments=True)
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=1)
    with assert_raises():
        _ = index.updated(rows, control=Optional(control.copy()))
    token.cancel()
    with assert_raises():
        _ = index.updated([], control=Optional(control.copy()))
    with assert_raises():
        _ = index.search(LanceBitmapQuery.is_null(), control=Optional(control.copy()))
    with assert_raises():
        _ = index.remapped({}, control=Optional(control.copy()))


def test_json_converted_values_reach_the_real_bitmap_target() raises:
    var texts: List[String] = ["true", "false", "7", "1.5", "'漢字'", "[1,2]", "{a:1}"]
    for text in texts:
        var input: List[Optional[JsonbValue]] = [None, Optional(parse_jsonb(text)), Optional(parse_jsonb(text))]
        var extracted = extract_json_index_batch(input, "$")
        var target = infer_json_index_type(extracted, "$").value()
        var converted = convert_json_index_batch(extracted, target, "$")
        var rows = List[LanceBitmapRow]()
        for i in range(len(converted)):
            rows.append(LanceBitmapRow(LanceScalarKey.from_json_result(converted[i], target), UInt64(i)))
        var index = LanceBitmapIndex.build(target, rows)
        var selected = index.search(LanceBitmapQuery.equals(LanceScalarKey.from_json_result(converted[1], target)))
        assert_equal(selected.selected_rows.count(), 2)
        assert_true(selected.selected_rows.contains(1))
        assert_true(selected.selected_rows.contains(2))
        assert_true(selected.nulls.contains(0))
    var wrong = LanceJsonResult()
    wrong.boolean = Optional(True)
    with assert_raises():
        _ = LanceScalarKey.from_json_result(wrong, 2)


def test_exact_logical_state_bound_and_expired_deadline() raises:
    var rows: List[LanceBitmapRow] = [LanceBitmapRow(LanceScalarKey.text("abc"), 0)]
    var index = LanceBitmapIndex.build(4, rows)
    assert_equal(LanceBitmapIndex.build(4, rows, max_bytes=index._bytes)._bytes, index._bytes)
    with assert_raises():
        _ = LanceBitmapIndex.build(4, rows, max_bytes=index._bytes-1)
    var token = CancellationToken()
    var expired = QueryControl(token, max_candidates=100, deadline_ns=1)
    with assert_raises():
        _ = index.search(LanceBitmapQuery.is_null(), control=Optional(expired.copy()))
    with assert_raises():
        _ = index.merge_sorted([], control=Optional(expired.copy()))
    with assert_raises():
        _ = index.remapped({}, control=Optional(expired.copy()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
