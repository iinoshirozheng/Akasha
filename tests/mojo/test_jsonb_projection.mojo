from akasha.query.jsonb_projection import JsonbProjection
from akasha.document.json_reader import parse_json
from akasha.document.jsonb_reader import parse_jsonb
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.jsonb import JsonbValue, _read_be
from akasha.document.lance_json_result import LanceJsonResult
from std.python import Python, PythonObject
from std.memory import bitcast
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite
from std.math import isnan, isinf


def test_native_computed_values_and_nested_calls() raises:
    var fields: List[DocumentField] = [DocumentField("data", PayloadValue.jsonb(
        parse_jsonb("{profile:{name:'Alice'},price:1.5,yes:'YES',values:[1,2],nan:NaN,inf:Infinity}")))]
    var projection = JsonbProjection(parse_json("""{"function":"json_get_string","input":{"function":"json_get","input":"data","argument":"profile"},"argument":"name"}"""))
    assert_equal(projection.evaluate(fields).text.value(), "Alice")
    var floating = JsonbProjection(parse_json("""{"function":"json_get_float","input":"data","argument":"nan"}"""))
    assert_true(isnan(floating.evaluate(fields).floating.value()))
    var infinity = JsonbProjection(parse_json("""{"function":"json_get_float","input":"data","argument":"inf"}"""))
    assert_true(isinf(infinity.evaluate(fields).floating.value()))
    var typed = JsonbProjection(parse_json("""{"function":"json_extract_with_type","input":"data","argument":"$.values"}"""))
    assert_equal(typed.evaluate(fields).type_tag, UInt8(5))
    assert_true(Bool(typed.evaluate(fields).binary))
    assert_equal(typed.evaluate([]).type_tag, UInt8(0))
    assert_false(Bool(typed.evaluate([]).binary))


def test_configuration_errors_and_source_nulls() raises:
    for spec in ["""{"function":"bad","input":"data","argument":"$"}""",
                 """{"function":"json_exists","input":"data","argument":"$["}""",
                 """{"function":"json_get_int","input":{"function":"json_get_string","input":"data","argument":"x"},"argument":"x"}""",
                 """{"function":"json_array_contains","input":"data","argument":"$"}""",
                 """{"function":"json_get","input":"data","argument":"x","extra":true}""",
                 """{"function":"json_get","input":"data","argument":"x","max_work":0}"""]:
        with assert_raises():
            _ = JsonbProjection(parse_json(spec))
    var projection = JsonbProjection(parse_json("""{"function":"json_exists","input":"data","argument":null}"""))
    var fields: List[DocumentField] = [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{}")))]
    assert_false(Bool(projection.evaluate(fields).boolean))


def test_inner_evaluation_precedes_outer_null_argument() raises:
    var projection = JsonbProjection(parse_json("""{"function":"json_get_string","input":{"function":"json_get","input":"data","argument":"profile"},"argument":null,"max_work":1}"""))
    var fields: List[DocumentField] = [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{profile:{x:1},extra:2}")))]
    with assert_raises():
        _ = projection.evaluate(fields)
    var constant_null = JsonbProjection(parse_json("""{"function":"json_exists","input":"data","argument":null}"""))
    with assert_raises():
        _ = constant_null.evaluate([DocumentField("data", PayloadValue.string("wrong type"))])


def _bytes(hex: PythonObject) raises -> List[UInt8]:
    var builtins = Python.import_module("builtins")
    var result = List[UInt8]()
    for byte in builtins.bytes.fromhex(hex):
        result.append(UInt8(Int(py=byte)))
    return result^


def _same_result(result: LanceJsonResult, op: Int, expected: PythonObject) raises:
    if op == 2:
        assert_equal(result.type_tag, UInt8(Int(py=expected["type_tag"])))
        if Bool(py=expected["value"] == Python.none()):
            assert_false(Bool(result.binary))
        else:
            assert_true(Bool(result.binary))
            assert_equal(result.binary.value().to_bytes(), _bytes(expected["value"]))
    elif Bool(py=expected == Python.none()):
        assert_false(result.valid(op))
    else:
        assert_true(result.valid(op))
        if op == 0 or op == 1 or op == 5:
            assert_equal(result.text.value(), String(py=expected))
        elif op == 4:
            assert_equal(result.binary.value().to_bytes(), _bytes(expected))
        elif op == 6 or op == 10:
            assert_equal(result.integer.value(), Int64(Int(py=expected)))
        elif op == 7:
            var bytes = _bytes(expected)
            assert_equal(bitcast[DType.uint64](result.floating.value()), _read_be(Span(bytes), 0, 8))
        else:
            assert_equal(result.boolean.value(), Bool(py=expected))


def test_all_original_scalar_projection_outcomes() raises:
    var builtins = Python.import_module("builtins")
    var json = Python.import_module("json")
    var source = json.loads(builtins.open("tests/fixtures/lance-json-functions/cases.json").read())
    var functions: List[String] = ["json_path", "json_extract", "json_extract_with_type",
        "json_exists", "json_get", "json_get_string", "json_get_int", "json_get_float",
        "json_get_bool", "json_array_contains", "json_array_length"]
    var count = 0
    for row in source:
        # Constant, non-null arguments and one valid stored body form the
        # scanner's scalar input contract. Other Arrow/null-mask shapes and
        # over-depth raw inputs remain covered by the original consumer suite.
        if len(row["bodies"]) != 1 or len(row["args"]) != 1:
            continue
        if Bool(py=row["bodies"][0] == Python.none()) or Bool(py=row["args"][0] == Python.none()):
            continue
        if Bool(py=row.__contains__("input_limit")):
            continue
        var bytes = _bytes(row["bodies"][0])
        var fields: List[DocumentField] = [DocumentField("data", PayloadValue.jsonb(JsonbValue(Span(bytes))))]
        for op in range(11):
            var key = String(op)
            if not Bool(py=row["results"].__contains__(key)):
                continue
            var spec = Python.dict(function=PythonObject(functions[op]), argument=row["args"][0])
            spec["input"] = PythonObject("data")
            if op == 9:
                if len(row["values"]) != 1 or Bool(py=row["values"][0] == Python.none()):
                    continue
                spec["needle"] = row["values"][0]
            var config = parse_json(String(py=json.dumps(spec)))
            var expected = row["results"][key]
            if not Bool(py=expected.__contains__("ok")):
                with assert_raises():
                    _ = JsonbProjection(config).evaluate(fields)
            else:
                _same_result(JsonbProjection(config).evaluate(fields), op, expected["ok"][0])
            count += 1
    assert_equal(count, 215_780)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
