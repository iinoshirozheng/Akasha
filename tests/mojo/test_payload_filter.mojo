from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.json_path import JsonPath
from akasha.index.metadata import MetadataIndex
from akasha.query.payload_condition import PayloadCondition, _uint
from akasha.query.point_condition import PointCondition
from akasha.query.filter_ast import FilterExpression, FilterCondition
from akasha.query.evaluator import matches_expression
from akasha.query.index_evaluator import evaluate_expression
from bindings.payload_python import json_value_from_python
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_raises, TestSuite


def _expression(value: PythonObject) raises -> FilterExpression:
    var kind = String(py=value["kind"])
    if kind == "field":
        return FilterExpression.field(PayloadCondition(json_value_from_python(value)))
    if kind == "has_id" or kind == "has_vector" or kind == "slice":
        return FilterExpression.point(PointCondition(json_value_from_python(value)))
    if kind == "is_empty" or kind == "is_null":
        var key = json_value_from_python(value["key"]).as_string()
        return FilterExpression.is_empty(key) if kind == "is_empty" else FilterExpression.is_null(key)
    if kind == "nested":
        return FilterExpression.nested(String(py=value["key"]), _expression(value["filter"]))
    if kind == "not":
        return FilterExpression.negate(_expression(value["child"]))
    var children = List[FilterExpression]()
    for child in value["children"]:
        children.append(_expression(child))
    if kind == "at_least":
        return FilterExpression.at_least(children^, _uint(json_value_from_python(value["min_count"])))
    if kind == "all":
        return FilterExpression.all(children^)
    return FilterExpression.any(children^)


def test_original_qdrant_predicates_direct_and_metadata() raises:
    var rows = Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-payload-filter/filters.json").read())["cases"]
    for i in range(len(rows)):
        var row = rows[i]
        if Bool(py=row.__contains__("error")):
            with assert_raises():
                _ = _expression(row["filter"])
            continue
        var expression = _expression(row["filter"])
        var fields = List[DocumentField]()
        for key in row["payload"]:
            fields.append(DocumentField(String(py=key), json_value_from_python(row["payload"][key])))
        var expected = Bool(py=row["matches"])
        assert_equal(matches_expression(fields, expression), expected, "direct source case " + String(i))
        var index = MetadataIndex()
        index.upsert(42, fields^)
        var result = evaluate_expression(index, expression)
        assert_equal(index.contains_id(result, 42), expected, "indexed source case " + String(i))
        index.delete(42)
        assert_equal(evaluate_expression(index, expression).count(), 0)


def test_clone_and_literal_name_contract() raises:
    var json = Python.import_module("json")
    var fields = List[DocumentField]()
    fields.append(DocumentField("a.b", PayloadValue.integer(1)))
    fields.append(DocumentField("a", json_value_from_python(json.loads('{"b":2}'))))
    var literal = FilterExpression.condition(FilterCondition.equal("a.b", PayloadValue.integer(1)))
    assert_equal(matches_expression(fields, literal), True)
    var path = _expression(json.loads('{"kind":"field","key":"a.b","match":{"value":2}}'))
    assert_equal(matches_expression(fields, path.clone()), True)
    var nested = _expression(json.loads('{"kind":"nested","key":"a","filter":{"kind":"all","children":[]}}'))
    assert_equal(matches_expression(fields, nested.clone()), False)
    var retargeted = PayloadCondition(json_value_from_python(json.loads('{"key":"missing","match":{"value":2}}')))
    retargeted.key = JsonPath.parse("a.b")
    var owned = FilterExpression.field(retargeted.clone())
    assert_equal(matches_expression(fields, owned.clone()), True)
    var minimum = FilterExpression.at_least([literal.clone(), path.clone()], 2)
    assert_equal(matches_expression(fields, minimum.clone()), True)


def test_native_filter_rejects_unsupported_or_malformed_requests() raises:
    var json = Python.import_module("json")
    var inputs: List[String] = [
        "{}", "[]", "null", '{"key":"x"}', '{"key":"x","unknown":1}',
        '{"key":"x","geo_polygon":{}}', '{"key":"x","is_null":0}',
        '{"key":"x","match":{"value":null}}', '{"key":"x","match":{"value":1,"any":[1]}}',
        '{"key":"x","values_count":{"gte":true}}', '{"key":"x","range":{"gte":"invalid"}}',
    ]
    for text in inputs:
        with assert_raises():
            _ = PayloadCondition(json_value_from_python(json.loads(text)))
    var child = FilterExpression.all([])
    for _ in range(FilterExpression.MAX_DEPTH - 1):
        child = FilterExpression.nested("items", child^)
    with assert_raises():
        _ = FilterExpression.nested("items", child^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
