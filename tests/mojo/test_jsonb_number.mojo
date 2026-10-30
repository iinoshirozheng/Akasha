from akasha.document.jsonb import JsonbValue, _read_be
from akasha.document import JsonbNumber
from akasha.document.jsonb_number import _Wide
from akasha.document.jsonb_formatting import _read128
from std.math import isnan
from std.memory import bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def _bytes(hex: PythonObject) raises -> List[UInt8]:
    var result = List[UInt8]()
    var builtins = Python.import_module("builtins")
    for b in builtins.bytes.fromhex(hex):
        result.append(UInt8(Int(py=b)))
    return result^


def _number(input: PythonObject) raises -> JsonbNumber:
    var bytes = _bytes(input[1])
    var kind = Int(py=input[0])
    if kind == 0:
        return JsonbNumber.integer(bitcast[DType.int64](_read_be(Span(bytes), 0, 8)))
    if kind == 1:
        return JsonbNumber.unsigned(_read_be(Span(bytes), 0, 8))
    if kind == 2:
        return JsonbNumber.floating(bitcast[DType.float64](_read_be(Span(bytes), 0, 8)))
    return JsonbNumber.decimal(Span(bytes), UInt8(Int(py=input[2])))


def _same(actual: JsonbNumber, expected: JsonbNumber) raises:
    assert_equal(actual.kind, expected.kind)
    assert_equal(actual.scale, expected.scale)
    if actual.kind == 2 and isnan(expected.as_f64()):
        # Rust arithmetic does not promise a NaN sign/payload. Preserve bits for
        # literal identity, but compare arithmetic NaNs by classification.
        assert_true(isnan(actual.as_f64()))
    else:
        assert_equal(actual.value.high, expected.value.high)
        assert_equal(actual.value.low, expected.value.low)


def _operation(a: JsonbNumber, b: JsonbNumber, op: Int) raises -> JsonbNumber:
    if op == 0:
        return a.add(b)
    if op == 1:
        return a.sub(b)
    if op == 2:
        return a.mul(b)
    if op == 3:
        return a.div(b)
    if op == 4:
        return a.rem(b)
    return a.neg()


def _check_operation(a: JsonbNumber, b: JsonbNumber, op: Int, expected: PythonObject) raises:
    var failed = False
    var result = JsonbNumber()
    var message = String()
    try:
        result = _operation(a, b, op)
    except error:
        failed = True
        message = String(error)
    if Bool(py=expected.__contains__("error")):
        assert_true(failed)
        assert_equal(message, String(py=expected["error"]))
    else:
        assert_true(not failed, message)
        _same(result, _number(expected["number"]))


def test_original_number_all_variants_and_operations() raises:
    var builtins = Python.import_module("builtins")
    var json = Python.import_module("json")
    var corpus = json.loads(builtins.open("tests/fixtures/jsonb-number/cases.json").read())
    var values = List[JsonbNumber]()
    var index = 0
    for row in corpus["unary"]:
        try:
            var value = _number(row["input"])
            values.append(value)
            _check_operation(value, value, 5, row["neg"])
            assert_equal(String(bitcast[DType.uint64](value.as_f64())), String(py=row["float"]))
            var encoded = value.to_value()
            var expected = _bytes(row["hex"])
            assert_equal(encoded.to_bytes(), expected)
            _same(JsonbNumber.from_value(encoded), _number(row["decoded"]))
        except error:
            print("JSONB Number unary", index, row["input"])
            raise error
        index += 1
    var pairs = 0
    for row in corpus["pairs"]:
        var left = Int(py=row["pair"][0])
        var right = Int(py=row["pair"][1])
        var op = -1
        try:
            assert_equal(values[left].cmp(values[right]), Int(py=row["cmp"]))
            for i in range(5):
                op = i
                _check_operation(values[left], values[right], i, row["ops"][i])
        except error:
            print("JSONB Number pair/op", pairs, op, corpus["unary"][left]["input"], corpus["unary"][right]["input"])
            raise error
        pairs += 1
    assert_equal(index, len(corpus["unary"]))
    assert_equal(pairs, len(corpus["pairs"]))
    assert_equal(index, 8495)
    assert_equal(pairs, 94213)


def _wide(input: PythonObject) raises -> _Wide:
    var bytes = _bytes(input)
    return _Wide(_read128(Span(bytes), 0), _read128(Span(bytes), 16))


def test_original_ethnum_checked_and_wrapping_multiply() raises:
    var builtins = Python.import_module("builtins")
    var json = Python.import_module("json")
    var corpus = json.loads(builtins.open("tests/fixtures/jsonb-number/cases.json").read())
    var index = 0
    for row in corpus["wide"]:
        try:
            var a = _wide(row["pair"][0])
            var b = _wide(row["pair"][1])
            assert_equal(a.cmp(b), Int(py=row["cmp"]))
            var expected = _wide(row["mul"])
            var actual = a.mul(b)
            assert_equal(actual.high, expected.high)
            assert_equal(actual.low, expected.low)
            var checked = a.checked_mul(b)
            if Bool(py=row["checked"] == Python.none()):
                assert_true(not checked)
            else:
                assert_true(checked)
                expected = _wide(row["checked"])
                assert_equal(checked.value().high, expected.high)
                assert_equal(checked.value().low, expected.low)
        except error:
            print("ethnum multiply case", index, row)
            raise error
        index += 1
    assert_equal(index, 2404)


def test_number_value_boundary_and_source_quirks() raises:
    for value in [JsonbValue.null(), JsonbValue.boolean(True), JsonbValue.string("1"), JsonbValue.array(List[JsonbValue]())]:
        with assert_raises():
            _ = JsonbNumber.from_value(value)
    for width in [0, 1, 7, 9, 15, 17, 31, 33]:
        var invalid = List[UInt8](length=width, fill=UInt8(0))
        with assert_raises():
            _ = JsonbNumber.decimal(Span(invalid), 0)
    # The source signed/unsigned casts precede checked arithmetic.
    var value = JsonbNumber.integer(-1).add(JsonbNumber.unsigned(UInt64.MAX))
    assert_equal(value.kind, 0)
    assert_equal(value.as_f64(), Float64(-2))
    var remainder = JsonbNumber.integer(-5).rem(JsonbNumber.integer(2))
    assert_equal(remainder.as_f64(), Float64(-1))
    var zero = JsonbNumber.integer(0)
    assert_equal(zero.kind, 0)
    assert_equal(JsonbNumber.from_value(zero.to_value()).kind, 1)
    # Canonical JSONB bodies and expression Number variants are separate.
    var nan = JsonbNumber.floating(bitcast[DType.float64](UInt64(0x7ff8000000001234)))
    assert_equal(UInt64(nan.value.low), UInt64(0x7ff8000000001234))
    assert_equal(nan.cmp(JsonbNumber.floating(bitcast[DType.float64](UInt64(0x7ff0000000000000)))), 1)


def test_original_power_wrap_and_legacy_numeric_bodies() raises:
    var builtins = Python.import_module("builtins")
    var json = Python.import_module("json")
    var corpus = json.loads(builtins.open("tests/fixtures/jsonb-number/cases.json").read())
    assert_equal(len(corpus["powers"]), 256)
    assert_equal(len(corpus["bodies"]), 4709)
    for row in corpus["powers"]:
        var actual = _Wide(0, 10).pow(Int(py=row[0]))
        var expected = _wide(row[1])
        assert_equal(actual.high, expected.high)
        assert_equal(actual.low, expected.low)
        var narrow = _bytes(row[2])
        assert_equal(actual.low, _read128(Span(narrow), 0))
    for row in corpus["bodies"]:
        var bytes = _bytes(row["hex"])
        var value = JsonbNumber.from_value(JsonbValue(Span(bytes)))
        _same(value, _number(row["number"]))
        var canonical = _bytes(row["canonical"])
        assert_equal(value.to_value().to_bytes(), canonical)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
