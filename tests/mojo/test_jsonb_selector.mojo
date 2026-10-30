from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_path import JsonbPath, JsonbPathNode
from akasha.document.jsonb_reader import parse_jsonb
from akasha.document import JsonbSelector
from akasha.document.jsonb_writer import format_jsonb
from akasha.query.control import QueryControl, CancellationToken
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite


def _bytes(hex: PythonObject) raises -> List[UInt8]:
    var builtins = Python.import_module("builtins")
    var bytes = List[UInt8]()
    for byte in builtins.bytes.fromhex(hex):
        bytes.append(UInt8(Int(py=byte)))
    return bytes^


def _same(value: JsonbValue, expected: PythonObject) raises:
    var bytes = _bytes(expected)
    assert_equal(value.to_bytes(), bytes)


def _optional(value: Optional[JsonbValue], expected: PythonObject) raises:
    if Bool(py=expected == Python.none()):
        assert_false(Bool(value))
    else:
        assert_true(Bool(value))
        _same(value.value(), expected)


def _mode(selector: JsonbSelector, path: JsonbPath, mode: Int, expected: PythonObject) raises:
    var check = Bool(py=expected.__contains__("ok"))
    if mode == 0:
        var values = selector.select_values(path)
        if check:
            assert_equal(len(values), len(expected["ok"]))
            for i in range(len(values)):
                _same(values[i], expected["ok"][i])
    elif mode == 1:
        var value = selector.select_array(path)
        if check:
            _same(value, expected["ok"])
    elif mode == 2:
        var value = selector.select_first(path)
        if check:
            _optional(value, expected["ok"])
    elif mode == 3:
        var value = selector.select_value(path)
        if check:
            _optional(value, expected["ok"])
    elif mode == 4:
        var value = selector.exists(path)
        if check:
            assert_equal(value, Bool(py=expected["ok"]))
    else:
        var value = selector.predicate_match(path)
        if check:
            if Bool(py=expected["ok"] == Python.none()):
                assert_false(Bool(value))
            else:
                assert_true(Bool(value))
                assert_equal(value.value(), Bool(py=expected["ok"]))


def test_all_six_original_selector_modes() raises:
    var builtins = Python.import_module("builtins")
    var json = Python.import_module("json")
    var corpus = json.loads(builtins.open("tests/fixtures/jsonb-selector/cases.json").read())
    var docs = List[JsonbValue]()
    for raw in corpus["docs"]:
        var bytes = _bytes(raw)
        docs.append(JsonbValue(Span(bytes)))
    var count = 0
    var modes = 0
    for row in corpus["cases"]:
        var doc = Int(py=row["pair"][0])
        var path_index = Int(py=row["pair"][1])
        var bytes = _bytes(corpus["paths"][path_index])
        if not Bool(py=row.__contains__("modes")):
            with assert_raises():
                _ = JsonbPath.parse_bytes(Span(bytes))
            count += 1
            continue
        var path = JsonbPath.parse_bytes(Span(bytes))
        var selector = JsonbSelector(docs[doc].clone())
        for mode in range(6):
            var failed = False
            var message = String()
            try:
                _mode(selector, path, mode, row["modes"][mode])
            except error:
                failed = True
                message = String(error)
            try:
                if Bool(py=row["modes"][mode].__contains__("output_limit")):
                    assert_true(failed)
                    assert_true(message.__contains__("resource limit"))
                elif Bool(py=row["modes"][mode].__contains__("error")):
                    assert_true(failed)
                    assert_equal(message, String(py=row["modes"][mode]["error"]))
                elif Bool(py=row["modes"][mode].__contains__("panic")):
                    assert_true(failed)
                else:
                    assert_false(failed, message)
            except error:
                print("selector source case/mode", count, mode, corpus["docs"][doc], String(from_utf8=Span(bytes)))
                print("expected", row["modes"][mode], "native error", message)
                raise error
            modes += 1
        count += 1
    assert_equal(count, 64856)
    assert_equal(modes, 389100)


def test_output_modes_unknown_order_and_source_serialization() raises:
    var selector = JsonbSelector(parse_jsonb("[1,2,3]"))
    var path = JsonbPath.parse("$[0,0 to 1,last]")
    assert_equal(format_jsonb(selector.select_array(path)), "[1,1,2,3]")
    assert_equal(format_jsonb(selector.select_first(path).value()), "1")
    assert_equal(format_jsonb(selector.select_value(path).value()), "[1,1,2,3]")
    assert_true(selector.exists(JsonbPath.parse("$ == 99")))
    assert_false(selector.predicate_match(JsonbPath.parse("$ == 99")).value())
    assert_false(Bool(selector.predicate_match(JsonbPath.parse("$"))))
    assert_equal(format_jsonb(JsonbSelector(parse_jsonb("[{},1]")).select_array(JsonbPath.parse("$ == 1"))), "[null]")
    assert_equal(format_jsonb(JsonbSelector(parse_jsonb("[1,{}]")).select_array(JsonbPath.parse("$ == 1"))), "[true]")
    assert_equal(format_jsonb(JsonbSelector(parse_jsonb("{a:1,b:{}}" )).select_array(JsonbPath.parse("$.a == 1 || $.b == 2"))), "[null]")
    var coefficient = List[UInt8](length=16, fill=UInt8(0))
    coefficient[15] = 123
    var decimal = JsonbValue.decimal(Span(coefficient), 2)
    var decimal_selector = JsonbSelector(decimal.clone())
    assert_equal(decimal_selector.select_first(JsonbPath.parse("$")).value().kind(), 9)
    var plus = decimal_selector.select_first(JsonbPath.parse("+$"))
    assert_equal(plus.value().kind(), 3)
    assert_equal(plus.value().as_float(), Float64(1.23))


def test_reuse_after_errors_and_owned_results() raises:
    var selector = JsonbSelector(parse_jsonb("{a:3,b:[1,2]}"))
    with assert_raises():
        _ = selector.select_value(JsonbPath.parse("$.a / 0"))
    var results = selector.select_values(JsonbPath.parse("$.b[*]"))
    selector.root = parse_jsonb("null")
    assert_equal(format_jsonb(results[0]), "1")
    assert_equal(format_jsonb(results[1]), "2")
    assert_false(selector.exists(JsonbPath.parse("$.b")))
    assert_equal(format_jsonb(selector.select_array(JsonbPath.parse("$[*]"))), "[null]")


def test_bounds_cancellation_deadline_and_unsafe_source_ranges() raises:
    var root = parse_jsonb("[1,2,3]")
    var path = JsonbPath.parse("$[*]")
    with assert_raises():
        _ = JsonbSelector(root.clone(), max_results=2).select_values(path)
    with assert_raises():
        _ = JsonbSelector(root.clone(), max_results=2).select_first(path)
    with assert_raises():
        _ = JsonbSelector(root.clone(), max_work=1).exists(path)
    with assert_raises():
        _ = JsonbSelector(root.clone(), max_bytes=1).select_values(path)
    with assert_raises():
        _ = JsonbSelector(root.clone(), max_bytes=1).select_array(JsonbPath.parse("$.missing"))
    for text in ["$[0 to -1]", "$[last to last--2147483648]"]:
        with assert_raises():
            _ = JsonbSelector(root.clone()).select_values(JsonbPath.parse(text))
    with assert_raises():
        _ = JsonbSelector(parse_jsonb("[]")).select_values(JsonbPath.parse("$[0 to last]"))
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=100)
    var selector = JsonbSelector(root.clone(), control=control.copy())
    token.cancel()
    with assert_raises():
        _ = selector.select_values(path)
    var deadline_token = CancellationToken()
    var deadline = QueryControl(deadline_token, max_candidates=100, deadline_ns=1)
    with assert_raises():
        _ = JsonbSelector(root.clone(), control=deadline.copy()).select_values(path)
    var budget = QueryControl(deadline_token, max_candidates=1)
    with assert_raises():
        _ = JsonbSelector(root.clone(), control=budget.copy()).select_values(path)
    for limit in [0, -1]:
        with assert_raises():
            _ = JsonbSelector(root.clone(), max_work=limit)
        with assert_raises():
            _ = JsonbSelector(root.clone(), max_results=limit)
        with assert_raises():
            _ = JsonbSelector(root.clone(), max_bytes=limit)


def test_mutated_ast_validation_and_manual_literal_expression() raises:
    var selector = JsonbSelector(parse_jsonb("null"))
    var path = JsonbPath.parse("$")
    path.roots[0] = 9
    with assert_raises():
        _ = selector.select_values(path)
    with assert_raises():
        _ = selector.predicate_match(path)
    path = JsonbPath.parse("$ == 1")
    path.nodes[0].children.append(0)
    with assert_raises():
        _ = selector.select_values(path)
    # Source Expr::Value (not emitted as a root by parse_json_path) wraps the
    # literal in an array. Preserve that behavior for valid native ASTs.
    var nodes: List[JsonbPathNode] = [
        JsonbPathNode(12, 2, 0, String(), 7, List[Int](), 1),
        JsonbPathNode(10, 0, 0, String(), 0, [0], 2),
    ]
    var literal = JsonbPath(nodes^, [1])
    assert_equal(format_jsonb(selector.select_array(literal)), "[[7]]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
