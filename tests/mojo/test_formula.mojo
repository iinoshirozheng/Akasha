from akasha.query.formula import Formula, FormulaDefault, FormulaNode
from akasha.document.json_path import FormulaVariable
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.geo import GeoPoint
from bindings.payload_python import json_value_from_python
from akasha.query.filter_ast import FilterExpression
from std.python import Python, PythonObject
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def test_formula_short_circuit_and_errors() raises:
    var multiply = Formula([
        FormulaNode("constant", value=0),
        FormulaNode("variable", key="missing"),
        FormulaNode("mult", [0, 1]),
    ])
    assert_equal(multiply.score(1, [], []), Float32(0))
    var divide = Formula([
        FormulaNode("constant", value=0),
        FormulaNode("variable", key="missing"),
        FormulaNode("div", [0, 1]),
    ])
    assert_equal(divide.score(1, [], []), Float32(0))
    var invalid = Formula([FormulaNode("constant", value=-1), FormulaNode("sqrt", [0])])
    with assert_raises():
        _ = invalid.score(1, [], [])


def test_formula_payload_defaults_and_f32_constants() raises:
    var formula = Formula([
        FormulaNode("variable", key="$score[1]"),
        FormulaNode("variable", key="weight"),
        FormulaNode("sum", [0, 1]),
    ], [FormulaDefault("$score[1]", PayloadValue.floating(1.25)),
        FormulaDefault("weight", PayloadValue.floating(2.5))])
    assert_equal(formula.score(1, [], []), Float32(3.75))
    var fields: List[DocumentField] = [DocumentField("weight", PayloadValue.string("wrong"))]
    with assert_raises():
        _ = formula.score(1, fields, [])
    var exact = Formula([
        FormulaNode("constant", value=16_777_216), FormulaNode("constant", value=1),
        FormulaNode("sum", [0, 1]), FormulaNode("constant", value=-16_777_216),
        FormulaNode("sum", [2, 3]),
    ])
    assert_equal(exact.score(1, [], []), Float32(1))


def test_formula_decay_and_reserved_variable_validation() raises:
    var formula = Formula([FormulaNode("constant", value=2), FormulaNode("gauss_decay", [0], scale=2)])
    assert_equal(formula.score(0, [], []), Float32(0.5))
    assert_equal(FormulaVariable.parse("$score").score_index.value(), UInt64(0))
    assert_equal(FormulaVariable.parse("$score[12]").score_index.value(), UInt64(12))
    with assert_raises():
        _ = FormulaVariable.parse("$score[]")
    with assert_raises():
        _ = FormulaVariable.parse("$score[1][2]")
    with assert_raises():
        _ = Formula([FormulaNode("constant"), FormulaNode("constant")])


def _fixture_expression(value: PythonObject, mut nodes: List[FormulaNode]) raises -> Int:
    var builtins = Python.import_module("builtins")
    if Bool(py=builtins.isinstance(value, builtins.str)):
        nodes.append(FormulaNode("variable", key=String(py=value)))
    elif not Bool(py=builtins.isinstance(value, builtins.dict)):
        nodes.append(FormulaNode("constant", value=Float32(py=value)))
    else:
        var kind = String(py=builtins.next(builtins.iter(value)))
        var arg = value[kind]
        var children = List[Int]()
        var default = Optional[Float32]()
        var condition = Optional[FilterExpression]()
        var midpoint = Float32(0.5)
        var scale = Float32(1)
        var origin = Optional[GeoPoint]()
        var key = String()
        if kind == "condition":
            condition = Optional(FilterExpression.all([]) if Bool(py=arg) else FilterExpression.any([]))
        elif kind == "geo_distance":
            var value = json_value_from_python(arg["origin"])
            origin = Optional(GeoPoint.from_payload(value))
            key = String(py=arg["to"])
        elif kind == "sum" or kind == "mult":
            for i in range(len(arg)):
                children.append(_fixture_expression(arg[i], nodes))
        elif kind == "div" or kind == "pow":
            children.append(_fixture_expression(arg["left" if kind == "div" else "base"], nodes))
            children.append(_fixture_expression(arg["right" if kind == "div" else "exponent"], nodes))
            if Bool(py=arg.__contains__("by_zero_default")):
                default = Optional(Float32(py=arg["by_zero_default"]))
        elif kind.endswith("_decay"):
            children.append(_fixture_expression(arg["x"], nodes))
            if Bool(py=arg.__contains__("target")):
                children.append(_fixture_expression(arg["target"], nodes))
            midpoint = Float32(py=arg.get("midpoint", 0.5))
            scale = Float32(py=arg.get("scale", 1))
        else:
            children.append(_fixture_expression(arg, nodes))
        nodes.append(FormulaNode(kind, children^, key=key, condition=condition^,
            by_zero_default=default, midpoint=midpoint, scale=scale, origin=origin^))
    return len(nodes) - 1


def _fixture_fields(value: PythonObject) raises -> List[DocumentField]:
    var builtins = Python.import_module("builtins")
    var keys = builtins.list(value)
    var fields = List[DocumentField]()
    for i in range(len(keys)):
        var raw = value[keys[i]]
        var item: PayloadValue
        if Bool(py=builtins.isinstance(raw, builtins.str)):
            item = PayloadValue.string(String(py=raw))
        elif Bool(py=builtins.isinstance(raw, builtins.bool)):
            item = PayloadValue.boolean(Bool(py=raw))
        else:
            item = PayloadValue.floating(Float64(py=raw))
        fields.append(DocumentField(String(py=keys[i]), item^))
    return fields^


def test_formula_matches_unedited_qdrant_scorer() raises:
    var builtins = Python.import_module("builtins")
    var cases = Python.import_module("json").loads(builtins.open(
        "tests/fixtures/qdrant-formula/formula.json").read())["cases"]
    for i in range(len(cases)):
        var sample = cases[i]
        var nodes = List[FormulaNode]()
        _ = _fixture_expression(sample["expression"], nodes)
        var raw_defaults = _fixture_fields(sample["defaults"])
        var defaults = List[FormulaDefault]()
        for j in range(len(raw_defaults)):
            defaults.append(FormulaDefault(raw_defaults[j].name, raw_defaults[j].value.clone()))
        var formula = Formula(nodes^, defaults^)
        var fields = _fixture_fields(sample["payload"])
        var scores = List[Dict[Int, Float32]]()
        for j in range(len(sample["scores"])):
            var raw = sample["scores"][j]
            var keys = builtins.list(raw)
            var values = Dict[Int, Float32]()
            for k in range(len(keys)):
                values[Int(py=builtins.int(keys[k]))] = Float32(py=raw[keys[k]])
            scores.append(values^)
        if Bool(py=sample["expected_bits"].__eq__(Python.none())):
            with assert_raises():
                _ = formula.score(1, fields, scores)
        else:
            var score = formula.score(1, fields, scores)
            assert_equal(bitcast[DType.uint32](score), UInt32(Int(py=sample["expected_bits"])),
                "source formula case " + String(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
