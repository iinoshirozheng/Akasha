from akasha.compute.robust_orientation import orient2d
from akasha.document.geo_polygon import GeoPolygon
from akasha.document.json_path import JsonPath
from akasha.document.record import DocumentField
from akasha.query.payload_condition import PayloadCondition, _uint
from akasha.query.filter_ast import FilterExpression
from akasha.query.evaluator import matches_expression
from akasha.query.index_evaluator import evaluate_expression
from akasha.index.metadata import MetadataIndex
from bindings.payload_python import json_value_from_python
from test_payload_filter import _expression
from std.memory import bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def fixture(name: String) raises -> PythonObject:
    return Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-polygon/" + name + ".json").read())


def test_robust_orientation_exact_source_bits_all_adaptive_stages() raises:
    var data = fixture("orientation")
    for count in data["coverage"]:
        assert_true(Int(py=count) > 0)
    var rows = data["cases"]
    for i in range(len(rows)):
        var values = List[Float64]()
        for bits in rows[i]["input_bits"]:
            values.append(bitcast[DType.float64](_uint(json_value_from_python(bits))))
        var actual = orient2d(values[0], values[1], values[2], values[3], values[4], values[5])
        assert_equal(bitcast[DType.uint64](actual), _uint(json_value_from_python(rows[i]["output_bits"])),
            "robust orientation source case " + String(i))


def test_polygon_original_qdrant_geo_source_direct_clone_metadata() raises:
    var rows = fixture("filters")["cases"]
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
        assert_equal(matches_expression(fields, expression), expected, "polygon source case " + String(i))
        assert_equal(matches_expression(fields, expression.clone()), expected, "polygon cloned case " + String(i))
        var index = MetadataIndex()
        index.upsert(42, fields^)
        var result = evaluate_expression(index, expression)
        assert_equal(index.contains_id(result, 42), expected, "polygon metadata case " + String(i))
        index.delete(42)
        assert_equal(evaluate_expression(index, expression).count(), 0)


def test_polygon_native_owned_geometry_and_retargeted_clone() raises:
    var json = Python.import_module("json")
    var value = json_value_from_python(json.loads('{"exterior":{"points":[[0,0],[4,0],[4,4],[0,4],[0,0]]},"interiors":[{"points":[[1,1],[2,1],[2,2],[1,2],[1,1]]}]}'))
    var polygon = GeoPolygon(value)
    var owned = polygon.copy()
    assert_equal(owned.contains(3, 3), True)
    assert_equal(owned.contains(1.5, 1.5), False)
    assert_equal(owned.contains(1, 1.5), False)
    assert_equal(owned.contains(0, 0), False)
    var spec = json.loads('{"key":"missing","geo_polygon":{"exterior":{"points":[[0,0],[4,0],[0,4],[0,0]]}}}')
    var condition = PayloadCondition(json_value_from_python(spec))
    condition.key = JsonPath.parse("place")
    var expression = FilterExpression.field(condition.clone())
    var fields: List[DocumentField] = [DocumentField("place", json_value_from_python(json.loads('{"lon":1,"lat":1}')))]
    assert_equal(matches_expression(fields, expression.clone()), True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
