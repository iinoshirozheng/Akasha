from akasha.document import JsonbPath, JsonbNumber, format_jsonb_path, format_jsonb_number_display
from akasha.document.jsonb import _read_be
from akasha.document.jsonb_number import _Wide, _wide_div128
from akasha.document.jsonb_formatting import _read128
from akasha.query.control import CancellationToken, QueryControl
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
    return json.loads(builtins.open("tests/fixtures/jsonb-display/cases.json").read())


def test_original_number_display_all_variants_scales_and_float_bits() raises:
    var corpus = _corpus()
    var count = 0
    var rejected = 0
    for row in corpus["numbers"]:
        try:
            var number = _number(row["input"])
            if Bool(py=row.__contains__("panic")):
                with assert_raises():
                    _ = format_jsonb_number_display(number)
                rejected += 1
            else:
                assert_equal(format_jsonb_number_display(number), String(py=row["text"]))
        except error:
            print("JSONB Number Display case", count, row)
            raise error
        count += 1
    assert_equal(count, 88716)
    assert_equal(rejected, 9058)


def test_original_path_display_complete_parser_corpus() raises:
    var corpus = _corpus()
    var count = 0
    var formatted = 0
    for row in corpus["paths"]:
        var bytes = _bytes(row["hex"])
        try:
            if Bool(py=row.__contains__("text")):
                var path = JsonbPath.parse_bytes(Span(bytes))
                assert_equal(format_jsonb_path(path), String(py=row["text"]))
                formatted += 1
            else:
                with assert_raises():
                    _ = JsonbPath.parse_bytes(Span(bytes))
        except error:
            print("JSONB path Display case", count, row)
            raise error
        count += 1
    assert_equal(count, 8525)
    assert_equal(formatted, 4238)


def test_original_ethnum_wide_by_narrow_unsigned_division() raises:
    var corpus = _corpus()
    var count = 0
    for row in corpus["divisions"]:
        try:
            var raw = _bytes(row["input"][0])
            var divisor = _bytes(row["input"][1])
            var value = _Wide(_read128(Span(raw), 0), _read128(Span(raw), 16))
            var q, r = _wide_div128(value, _read128(Span(divisor), 0))
            var quotient = _bytes(row["quotient"])
            var remainder = _bytes(row["remainder"])
            assert_equal(q.high, _read128(Span(quotient), 0))
            assert_equal(q.low, _read128(Span(quotient), 16))
            assert_equal(r, _read128(Span(remainder), 0))
        except error:
            print("ethnum division case", count, row)
            raise error
        count += 1
    assert_equal(count, 11692)
    with assert_raises():
        _ = _wide_div128(_Wide(0, 1), 0)


def test_display_contract_output_ownership_and_bounds() raises:
    var path = JsonbPath.parse(" $ [ 1 , last + 2 , 0 to last - 1 ] ")
    var result = format_jsonb_path(path)
    assert_equal(result, "$[1, last+2, 0 to last-1]")
    path = JsonbPath.parse("$")
    assert_equal(result, "$[1, last+2, 0 to last-1]")
    # Display writes decoded fields and string literals without JSON escaping.
    assert_equal(format_jsonb_path(JsonbPath.parse("$.\"a.b\"")), "$.a.b")
    assert_equal(format_jsonb_path(JsonbPath.parse("$ == \"a\\n\\\"b\"")), "$ == \"a\n\"b\"")
    assert_equal(format_jsonb_path(path, max_bytes=1), "$")
    with assert_raises():
        _ = format_jsonb_path(JsonbPath.parse("$.漢"), max_bytes=4)
    with assert_raises():
        _ = format_jsonb_path(path, max_work=1)
    for limit in [0, -1]:
        with assert_raises():
            _ = format_jsonb_path(path, max_bytes=limit)
        with assert_raises():
            _ = format_jsonb_path(path, max_work=limit)
        with assert_raises():
            _ = format_jsonb_number_display(JsonbNumber.integer(0), max_bytes=limit)
    assert_equal(format_jsonb_number_display(JsonbNumber.integer(123), max_bytes=3), "123")
    with assert_raises():
        _ = format_jsonb_number_display(JsonbNumber.integer(123), max_bytes=2)
    var invalid = JsonbNumber()
    invalid.kind = 6
    with assert_raises():
        _ = format_jsonb_number_display(invalid)
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=100)
    token.cancel()
    with assert_raises():
        _ = format_jsonb_path(path, control=control.copy())
    var live = CancellationToken()
    var deadline = QueryControl(live, max_candidates=100, deadline_ns=1)
    with assert_raises():
        _ = format_jsonb_path(path, control=deadline.copy())
    var budget = QueryControl(live, max_candidates=1)
    with assert_raises():
        _ = format_jsonb_path(path, control=budget.copy())


def test_mutated_ast_rejection_and_repeated_child_work_limit() raises:
    var path = JsonbPath.parse("$ == 1")
    path.roots[0] = len(path.nodes)
    with assert_raises():
        _ = format_jsonb_path(path)
    path = JsonbPath.parse("$ == 1")
    path.nodes[0].children.append(0)
    with assert_raises():
        _ = format_jsonb_path(path)
    path = JsonbPath.parse("$.a")
    path.nodes[1].text = "漢"
    assert_equal(format_jsonb_path(path), "$.漢")
    # Repeated roots are legal ASTs, but rendered visits still consume budget.
    for _ in range(100):
        path.roots.append(1)
    with assert_raises():
        _ = format_jsonb_path(path, max_work=10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
