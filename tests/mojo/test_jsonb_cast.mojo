from akasha.document import JsonbNumber, JsonbValue, jsonb_to_bool, jsonb_to_i64, jsonb_to_u64, jsonb_to_f64, jsonb_to_str
from akasha.document.jsonb import _read_be
from akasha.document.jsonb_number import _Wide, _wide_divmod
from akasha.document.jsonb_formatting import _read128
from std.memory import bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def _bytes(hex: PythonObject) raises -> List[UInt8]:
    var builtins = Python.import_module("builtins")
    var result = List[UInt8]()
    for byte in builtins.bytes.fromhex(hex):
        result.append(UInt8(Int(py=byte)))
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


def _corpus() raises -> PythonObject:
    var builtins = Python.import_module("builtins")
    var json = Python.import_module("json")
    return json.loads(builtins.open("tests/fixtures/jsonb-cast/cases.json").read())


def _same[T: Writable & Movable & Copyable](actual: Optional[T], expected: PythonObject) raises:
    if Bool(py=expected == Python.none()):
        assert_true(not actual)
    else:
        assert_true(Bool(actual))
        assert_equal(String(actual.value()), String(py=expected))


def test_original_number_exact_and_rounded_conversions() raises:
    var corpus = _corpus()
    var count = 0
    for row in corpus["numbers"]:
        try:
            var n = _number(row["input"])
            _same(n.as_i64(), row["as_i64"])
            _same(n.as_u64(), row["as_u64"])
            _same(n.to_i128(), row["to_i128"])
            _same(n.to_i64(), row["to_i64"])
            _same(n.to_u64(), row["to_u64"])
        except error:
            print("Number conversion case", count, row)
            raise error
        count += 1
    assert_equal(count, 96744)


def _cast(value: JsonbValue, mode: Int) raises -> String:
    if mode == 0:
        return "true" if jsonb_to_bool(value) else "false"
    if mode == 1:
        return String(jsonb_to_i64(value))
    if mode == 2:
        return String(jsonb_to_u64(value))
    if mode == 3:
        return String(bitcast[DType.uint64](jsonb_to_f64(value)))
    return jsonb_to_str(value)


def test_original_raw_jsonb_all_casts() raises:
    var corpus = _corpus()
    var count = 0
    for row in corpus["casts"]:
        var bytes = _bytes(row["hex"])
        var value = JsonbValue(Span(bytes))
        for mode in range(5):
            var expected = row["casts"][mode]
            var failed = False
            var result: String
            try:
                result = _cast(value, mode)
            except error:
                failed = True
                result = String(error)
            try:
                if Bool(py=expected.__contains__("error")):
                    assert_true(failed)
                    assert_equal(result, String(py=expected["error"]))
                elif Bool(py=expected.__contains__("panic")):
                    assert_true(failed)
                else:
                    assert_true(not failed, result)
                    var text = String(py=expected["ok"])
                    if mode == 0:
                        text = "true" if Bool(py=expected["ok"]) else "false"
                    assert_equal(result, text)
            except error:
                print("RawJsonb cast case/mode", count, mode, row)
                raise error
        count += 1
    assert_equal(count, 19975)


def test_original_ethnum_full_unsigned_division() raises:
    var corpus = _corpus()
    var count = 0
    for row in corpus["divisions"]:
        try:
            var a = _bytes(row["input"][0])
            var b = _bytes(row["input"][1])
            var dividend = _Wide(_read128(Span(a), 0), _read128(Span(a), 16))
            var divisor = _Wide(_read128(Span(b), 0), _read128(Span(b), 16))
            var q, r = _wide_divmod(dividend, divisor)
            var quotient = _bytes(row["quotient"])
            var remainder = _bytes(row["remainder"])
            assert_equal(q.high, _read128(Span(quotient), 0))
            assert_equal(q.low, _read128(Span(quotient), 16))
            assert_equal(r.high, _read128(Span(remainder), 0))
            assert_equal(r.low, _read128(Span(remainder), 16))
        except error:
            print("ethnum full division case", count, row)
            raise error
        count += 1
    assert_equal(count, 22188)
    with assert_raises():
        _ = _wide_divmod(_Wide(0, 1), _Wide(0, 0))


def test_source_cast_distinctions() raises:
    assert_true(not JsonbNumber.floating(1.5).as_i64())
    assert_equal(JsonbNumber.floating(1.5).to_i64().value(), Int64(2))
    assert_equal(JsonbNumber.floating(-1.5).to_i64().value(), Int64(-2))
    assert_equal(jsonb_to_i64(JsonbValue.string("9223372036854775807")), Int64.MAX)
    assert_equal(jsonb_to_u64(JsonbValue.string("18446744073709551615")), UInt64.MAX)
    assert_equal(jsonb_to_u64(JsonbValue.string("-0.49")), UInt64(0))
    assert_equal(jsonb_to_i64(JsonbValue.boolean(True)), Int64(1))
    assert_true(jsonb_to_bool(JsonbValue.string("YeS")))
    for value in [JsonbValue.integer(0), JsonbValue.integer(1), JsonbValue.string("1"), JsonbValue.string(" true"), JsonbValue.null()]:
        with assert_raises():
            _ = jsonb_to_bool(value)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
