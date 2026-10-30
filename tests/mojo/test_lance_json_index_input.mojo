from akasha.index.lance_json_input import (
    JsonIndexValue, extract_json_index_batch, infer_json_index_type,
    convert_json_index_batch, json_index_type_name,
)
from akasha.document.jsonb import JsonbValue, _read_be
from akasha.document.jsonb_reader import parse_jsonb
from akasha.document.lance_json_result import LanceJsonResult
from akasha.query.control import CancellationToken, QueryControl
from std.python import Python, PythonObject
from std.memory import bitcast
from std.sys import size_of
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite


def _hex(value: PythonObject) raises -> List[UInt8]:
    var bytes = Python.import_module("builtins").bytes.fromhex(value)
    var result = List[UInt8]()
    for byte in bytes:
        result.append(UInt8(Int(py=byte)))
    return result^


def _value(value: PythonObject) raises -> Optional[JsonbValue]:
    if Bool(py=value == Python.none()):
        return None
    var body = _hex(value)
    return Optional(JsonbValue(Span(body)))


def _batch(texts: List[String]) raises -> List[JsonIndexValue]:
    var values = List[Optional[JsonbValue]]()
    for text in texts:
        values.append(Optional(parse_jsonb(text)))
    return extract_json_index_batch(values, "$")


def test_first_nonnull_type_and_strict_serde_conversion() raises:
    var integers = _batch(["null", "1", "1.5"])
    assert_equal(infer_json_index_type(integers, "$").value(), UInt8(2))
    with assert_raises():
        _ = convert_json_index_batch(integers, 2, "$")
    var floats = _batch(["null", "1.5", "1"])
    assert_equal(infer_json_index_type(floats, "$").value(), UInt8(3))
    var converted = convert_json_index_batch(floats, 3, "$")
    assert_false(Bool(converted[0].floating))
    assert_equal(converted[1].floating.value(), Float64(1.5))
    assert_equal(converted[2].floating.value(), Float64(1))
    assert_false(Bool(infer_json_index_type(_batch(["null"]), "$")))
    assert_false(Bool(infer_json_index_type([], "$")))
    # The same fixed trained type must be used on later batches.
    with assert_raises():
        _ = convert_json_index_batch(_batch(["true"]), 3, "$")


def test_masks_and_whole_batch_validation_error_precedence() raises:
    var batch: List[JsonIndexValue] = [
        JsonIndexValue(Optional(parse_jsonb("true")), Optional(UInt8(2))),
        JsonIndexValue(Optional(parse_jsonb("1")), Optional(UInt8(4))),
    ]
    try:
        _ = convert_json_index_batch(batch, 2, "$")
        assert_true(False)
    except error:
        assert_equal(String(error), "JSON path '$' expected Int64, but batch row 1 has JSON type String")
    var ignored: List[JsonIndexValue] = [JsonIndexValue(None, Optional(UInt8(255)))]
    assert_false(Bool(convert_json_index_batch(ignored, 2, "$")[0].integer))
    with assert_raises():
        _ = infer_json_index_type(ignored, "$")
    var prefix: List[JsonIndexValue] = [
        JsonIndexValue(Optional(parse_jsonb("1")), Optional(UInt8(2))),
        JsonIndexValue(None, Optional(UInt8(255))),
    ]
    assert_equal(infer_json_index_type(prefix, "$").value(), UInt8(2))


def test_bounds_controls_and_owned_results() raises:
    var values: List[Optional[JsonbValue]] = [Optional(parse_jsonb("{a:[1,2]}")), None]
    var batch = extract_json_index_batch(values, "$.a")
    var result = convert_json_index_batch(batch, 5, "$.a")
    values.clear()
    batch.clear()
    assert_equal(result[0].binary.value().to_bytes(), parse_jsonb("[1,2]").to_bytes())
    assert_false(Bool(result[1].binary))
    with assert_raises():
        _ = convert_json_index_batch(_batch(["'abc'"]), 4, "$", max_bytes=1)
    with assert_raises():
        _ = extract_json_index_batch([Optional(parse_jsonb("1"))], "$", max_bytes=1)
    with assert_raises():
        _ = convert_json_index_batch([], 0, "$")
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=1)
    with assert_raises():
        _ = infer_json_index_type(_batch(["null", "1"]), "$", control=Optional(control.copy()))
    token.cancel()
    with assert_raises():
        _ = extract_json_index_batch([], "$", control=Optional(control.copy()))
    with assert_raises():
        _ = convert_json_index_batch([], 2, "$", control=Optional(control.copy()))


def test_exact_allocation_bounds_and_row_cap() raises:
    var fixed = size_of[LanceJsonResult]()
    var text = _batch(["'abc'"])
    assert_equal(convert_json_index_batch(text, 4, "$", max_bytes=fixed + 3)[0].text.value(), "abc")
    with assert_raises():
        _ = convert_json_index_batch(text, 4, "$", max_bytes=fixed + 2)
    var array = _batch(["[1,2]"])
    var binary_bytes = len(array[0].value.value()._data)
    assert_true(Bool(convert_json_index_batch(array, 5, "$", max_bytes=fixed + binary_bytes)[0].binary))
    with assert_raises():
        _ = convert_json_index_batch(array, 5, "$", max_bytes=fixed + binary_bytes - 1)
    var oversized = List[JsonIndexValue]()
    for _ in range(65_537):
        oversized.append(JsonIndexValue(None, Optional(UInt8(0))))
    with assert_raises():
        _ = infer_json_index_type(oversized, "$")
    with assert_raises():
        _ = convert_json_index_batch(oversized, 4, "$")


def _same(result: LanceJsonResult, target: UInt8, expected: PythonObject) raises:
    var op = 8 if target == 1 else 6 if target == 2 else 7 if target == 3 else 5 if target == 4 else 4
    if Bool(py=expected == Python.none()):
        assert_false(result.valid(op))
    elif target == 1:
        assert_equal(result.boolean.value(), Bool(py=expected))
    elif target == 2:
        assert_equal(result.integer.value(), Int64(Int(py=expected)))
    elif target == 3:
        var bits = _hex(expected)
        assert_equal(bitcast[DType.uint64](result.floating.value()), _read_be(Span(bits), 0, 8))
    elif target == 4:
        assert_equal(result.text.value(), String(py=expected))
    else:
        assert_equal(result.binary.value().to_bytes(), _hex(expected))


def test_original_lance_index_methods() raises:
    var builtins = Python.import_module("builtins")
    var rows = Python.import_module("json").loads(builtins.open("tests/fixtures/lance-json-index/cases.json").read())
    var comparisons = 0
    for row in rows:
        var path = String(py=row["path"])
        var expected = row["result"]
        var input_values = List[Optional[JsonbValue]]()
        for body in row["bodies"]:
            input_values.append(_value(body))
        if not Bool(py=expected["extraction"].__contains__("ok")):
            with assert_raises():
                _ = extract_json_index_batch(input_values, path)
            continue
        var batch = List[JsonIndexValue]()
        if not Bool(py=row.__contains__("tags")):
            batch = extract_json_index_batch(input_values, path)
        else:
            for i in range(len(input_values)):
                var tag = Optional[UInt8]()
                if not Bool(py=row["tags"][i] == Python.none()):
                    tag = Optional(UInt8(Int(py=row["tags"][i])))
                batch.append(JsonIndexValue(input_values[i].copy(), tag))
        var extracted = expected["extraction"]["ok"]
        assert_equal(len(batch), len(extracted))
        for i in range(len(batch)):
            if Bool(py=extracted[i]["value"] == Python.none()):
                assert_false(Bool(batch[i].value))
            else:
                assert_equal(batch[i].value.value().to_bytes(), _hex(extracted[i]["value"]))
            if Bool(py=extracted[i]["tag"] == Python.none()):
                assert_false(Bool(batch[i].tag))
            else:
                assert_equal(batch[i].tag.value(), UInt8(Int(py=extracted[i]["tag"])))
        var inferred = expected["inference"]
        if not Bool(py=inferred.__contains__("ok")):
            var failed = False
            try:
                _ = infer_json_index_type(batch, path)
            except error:
                failed = True
                assert_equal(String(error), String(py=inferred["error"]))
            assert_true(failed)
        else:
            var actual = infer_json_index_type(batch, path)
            if Bool(py=inferred["ok"] == Python.none()):
                assert_false(Bool(actual))
            else:
                assert_equal(json_index_type_name(actual.value()), String(py=inferred["ok"]))
        for number in range(1, 6):
            var target = UInt8(number)
            var source = expected["converted"][json_index_type_name(target)]
            if not Bool(py=source.__contains__("ok")):
                var failed = False
                try:
                    _ = convert_json_index_batch(batch, target, path)
                except error:
                    failed = True
                    if Bool(py=source.__contains__("error")):
                        assert_equal(String(error), String(py=source["error"]))
                assert_true(failed)
            else:
                var converted = convert_json_index_batch(batch, target, path)
                assert_equal(len(converted), len(source["ok"]))
                for i in range(len(converted)):
                    _same(converted[i], target, source["ok"][i])
            comparisons += 1
    assert_equal(comparisons, len(rows) * 5)
    print("Original Lance index conversions:", comparisons)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
