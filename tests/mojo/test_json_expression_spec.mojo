from akasha.query.json_expression_spec import parse_json_expression
from akasha.document.json_reader import parse_json
from akasha.document.jsonb_reader import parse_jsonb
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from std.testing import assert_equal, assert_raises, TestSuite


def test_public_specs_bind_and_execute_in_native_code() raises:
    var fields: List[DocumentField] = [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:2}")))]
    var projection = "\"projection\":{\"function\":\"json_get_int\",\"input\":\"data\",\"argument\":\"v\"}"
    for operator in ["eq", "ge", "le"]:
        var spec = "{\"kind\":\"predicate\"," + projection + ",\"operator\":\"" + operator + "\",\"value\":2}"
        assert_equal(parse_json_expression(parse_json(spec)).evaluate(fields).value(), True)
    var empty = parse_json_expression(parse_json("{\"kind\":\"all\",\"children\":[]}"))
    assert_equal(empty.evaluate(fields).value(), True)
    var nullable = "{\"kind\":\"predicate\"," + projection + ",\"operator\":\"in\",\"values\":[null,2]}"
    assert_equal(parse_json_expression(parse_json(nullable)).evaluate(fields).value(), True)
    for spec in ["{\"kind\":\"unknown\"}", "{\"kind\":\"all\",\"children\":[],\"typo\":true}"]:
        with assert_raises():
            _ = parse_json_expression(parse_json(spec))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
