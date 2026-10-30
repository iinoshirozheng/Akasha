from akasha.query.jsonb_condition import JsonbCondition
from akasha.query.filter_ast import FilterExpression
from akasha.query.filter_ast import FilterCondition
from akasha.query.evaluator import matches_expression
from akasha.query.index_evaluator import evaluate_expression
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.jsonb_reader import parse_jsonb
from akasha.document.jsonb import JsonbValue
from akasha.index.metadata import MetadataIndex
from std.python import Python, PythonObject
from std.testing import assert_true, assert_false, assert_equal, assert_raises, TestSuite


def _stored(text: String) raises -> List[DocumentField]:
    return [DocumentField("data", PayloadValue.jsonb(parse_jsonb(text)))]


def _filter(function: String, argument: String, var needle: Optional[String] = None) raises -> FilterExpression:
    return FilterExpression.jsonb(JsonbCondition("data", function, argument, needle=needle^))


def test_native_source_booleans_and_indexed_agreement() raises:
    var fields = _stored("{price:1.5,flag:'YES',items:[1,2],n:null}")
    var index = MetadataIndex()
    index.upsert(1, _stored("{price:1.5,flag:'YES',items:[1,2],n:null}"))
    for function, argument, expected in [("predicate_match", "$.price > 1", True),
            ("predicate_match", "$.missing == 1", False), ("predicate_match", "$", False),
            ("json_exists", "$.price == 99", True), ("json_exists", "$.missing", False),
            ("json_get_bool", "flag", True), ("json_get_bool", "n", False)]:
        var expression = _filter(function, argument)
        assert_equal(matches_expression(fields, expression), expected)
        assert_equal(index.contains_id(evaluate_expression(index, expression), 1), expected)
    var contains = _filter("json_array_contains", "$.items", Optional(String("2")))
    assert_true(matches_expression(fields, contains))
    assert_true(index.contains_id(evaluate_expression(index, contains), 1))
    with assert_raises():
        _ = matches_expression(fields, _filter("json_get_bool", "price"))
    with assert_raises():
        _ = matches_expression([DocumentField("data", PayloadValue.string("{}"))], contains)


def test_missing_null_nested_and_configuration_validation() raises:
    var expression = _filter("json_exists", "$")
    assert_false(matches_expression([], expression))
    assert_false(matches_expression([DocumentField("data", PayloadValue.null())], expression))
    var children = List[PayloadValue]()
    children.append(PayloadValue.object(["data"], [PayloadValue.jsonb(parse_jsonb("{yes:true}"))]))
    var fields: List[DocumentField] = [DocumentField("items", PayloadValue.array(children^))]
    var nested = FilterExpression.nested("items", _filter("predicate_match", "$.yes == true"))
    assert_true(matches_expression(fields, nested))
    with assert_raises():
        _ = _filter("unknown", "$")
    with assert_raises():
        _ = _filter("json_exists", "$[")
    with assert_raises():
        _ = _filter("json_array_contains", "$")
    with assert_raises():
        _ = _filter("json_exists", "$", Optional(String("x")))
    with assert_raises():
        _ = JsonbCondition("data", "json_exists", "$", max_work=0)
    with assert_raises():
        _ = matches_expression(_stored("[1,2,3]"), FilterExpression.jsonb(
            JsonbCondition("data", "json_exists", "$[*]", max_results=1)))


def test_boolean_short_circuit_masks_invalid_payloads_identically() raises:
    var fields: List[DocumentField] = [DocumentField("data", PayloadValue.string("not JSONB"))]
    var index = MetadataIndex()
    index.upsert(1, [DocumentField("data", PayloadValue.string("not JSONB"))])
    index.upsert(2, _stored("{yes:true}"))
    var expression = FilterExpression.any([
        FilterExpression.condition(FilterCondition.equal("data", PayloadValue.string("not JSONB"))),
        _filter("predicate_match", "$.yes == true")])
    assert_true(matches_expression(fields, expression))
    assert_equal(evaluate_expression(index, expression).count(), 2)
    var expression2 = FilterExpression.all([
        FilterExpression.negate(FilterExpression.condition(
            FilterCondition.equal("data", PayloadValue.string("not JSONB")))),
        _filter("predicate_match", "$.yes == true")])
    assert_false(matches_expression(fields, expression2))
    assert_equal(evaluate_expression(index, expression2).count(), 1)


def _body(raw: PythonObject) raises -> PayloadValue:
    var builtins = Python.import_module("builtins")
    var bytes = List[UInt8]()
    for item in builtins.bytes.fromhex(raw):
        bytes.append(UInt8(Int(py=item)))
    return PayloadValue.jsonb(JsonbValue(Span(bytes)))


def _original_outcome(raw: PythonObject, function: String, argument: String,
                      var needle: Optional[String], expected: PythonObject) raises:
    var fields: List[DocumentField] = [DocumentField("data", _body(raw))]
    var index = MetadataIndex()
    index.upsert(7, [DocumentField("data", _body(raw))])
    # Both paths must independently reject source failures, including invalid
    # configuration. Successful nullable source booleans match only true.
    if not Bool(py=expected.__contains__("ok")):
        with assert_raises():
            var expression = _filter(function, argument, needle.copy())
            _ = matches_expression(fields, expression)
        with assert_raises():
            var expression = _filter(function, argument, needle.copy())
            _ = evaluate_expression(index, expression)
    else:
        var expression = _filter(function, argument, needle^)
        var matches = Bool(py=expected["ok"] == PythonObject(True))
        assert_equal(matches_expression(fields, expression), matches)
        assert_equal(index.contains_id(evaluate_expression(index, expression), 7), matches)


def test_original_selector_predicate_results_in_direct_and_bitmap_filters() raises:
    var builtins = Python.import_module("builtins")
    var json = Python.import_module("json")
    var source = json.loads(builtins.open("tests/fixtures/jsonb-selector/cases.json").read())
    var count = 0
    for row in source["cases"]:
        # These rows are raw-byte parser rejection tests, not valid String API
        # inputs. Existing parser tests retain them; eager syntax errors above
        # cover the collection filter's distinct configuration contract.
        if not Bool(py=row.__contains__("modes")):
            continue
        var argument = String(py=builtins.bytes.fromhex(source["paths"][row["pair"][1]]).decode("utf-8"))
        _original_outcome(source["docs"][row["pair"][0]], "predicate_match", argument,
                          None, row["modes"][5])
        count += 1
    assert_equal(count, 64_850)


def test_original_lance_boolean_results_in_direct_and_bitmap_filters() raises:
    var builtins = Python.import_module("builtins")
    var json = Python.import_module("json")
    var source = json.loads(builtins.open("tests/fixtures/lance-json-functions/cases.json").read())
    var count = 0
    for row in source:
        # The filter has one non-null argument and one stored value. Arrow
        # broadcasting, null masks and malformed raw bodies remain covered by
        # test_lance_json; they are not this collection API's input contract.
        if len(row["bodies"]) != 1 or len(row["args"]) != 1:
            continue
        if Bool(py=row["bodies"][0] == Python.none()) or Bool(py=row["args"][0] == Python.none()):
            continue
        if Bool(py=row.__contains__("input_limit")):
            continue
        for op, function in [("3", "json_exists"), ("8", "json_get_bool"), ("9", "json_array_contains")]:
            if not Bool(py=row["results"].__contains__(op)):
                continue
            var needle = Optional[String]()
            if op == "9":
                if len(row["values"]) != 1 or Bool(py=row["values"][0] == Python.none()):
                    continue
                needle = Optional(String(py=row["values"][0]))
            var result = row["results"][op]
            if Bool(py=result.__contains__("ok")):
                result = Python.dict(ok=result["ok"][0])
            _original_outcome(row["bodies"][0], function, String(py=row["args"][0]), needle^, result)
            count += 1
    print("Source Lance boolean outcomes:", count)
    assert_true(count > 40_000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
