from akasha.document.datetime import DateTimeValue
from akasha.document.record import DocumentField
from akasha.query.formula import Formula, FormulaDefault, FormulaNode
from akasha.query.query_plan import QueryNode
from akasha.api.collection import PersistentCollection
from bindings.payload_python import json_value_from_python
from test_formula import _fixture_expression
from std.memory import bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_raises, TestSuite


def fixture() raises -> PythonObject:
    return Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-datetime/datetime.json").read())


def test_datetime_matches_original_qdrant_chrono_parser() raises:
    var rows = fixture()["dates"]
    for i in range(len(rows)):
        var row = rows[i]
        var label = String(i) + ": " + String(py=Python.import_module("builtins").repr(row["input"]))
        var accepted = False
        var actual = DateTimeValue(0)
        try:
            actual = DateTimeValue.from_payload(json_value_from_python(row["input"]))
            accepted = True
        except:
            pass
        assert_equal(accepted, not Bool(py=row.__contains__("error")), label)
        if accepted:
            assert_equal(actual.timestamp(), Int64(Int(py=row["micros"])), label)
            assert_equal(actual.seconds, Int64(Int(py=row["seconds"])), label)
            assert_equal(actual.nanoseconds, UInt32(Int(py=row["nanos"])), label)


def test_datetime_microsecond_roundtrip_matches_chrono() raises:
    var rows = fixture()["timestamps"]
    for i in range(len(rows)):
        var row = rows[i]
        var value = Int64(Int(py=row["input"]))
        if Bool(py=row.__contains__("error")):
            with assert_raises():
                _ = DateTimeValue.from_timestamp(value)
        else:
            var actual = DateTimeValue.from_timestamp(value)
            assert_equal(actual.timestamp(), value, String(i))
            assert_equal(actual.seconds, Int64(Int(py=row["seconds"])), String(i))
            assert_equal(actual.nanoseconds, UInt32(Int(py=row["nanos"])), String(i))


def test_datetime_formula_matches_original_qdrant_scorer() raises:
    var rows = fixture()["formulas"]
    for i in range(len(rows)):
        var row = rows[i]
        var nodes = List[FormulaNode]()
        _ = _fixture_expression(row["expression"], nodes)
        var fields = List[DocumentField]()
        for key in row["payload"]:
            fields.append(DocumentField(String(py=key), json_value_from_python(row["payload"][key])))
        var defaults = List[FormulaDefault]()
        for key in row["defaults"]:
            defaults.append(FormulaDefault(String(py=key), json_value_from_python(row["defaults"][key])))
        var formula = Formula(nodes^, defaults^)
        var scores = List[Dict[Int, Float32]]()
        if row["expected_bits"] is Python.none():
            with assert_raises():
                _ = formula.score(1, fields, scores)
        else:
            assert_equal(bitcast[DType.uint32](formula.score(1, fields, scores)),
                UInt32(Int(py=row["expected_bits"])), "datetime formula " + String(i))


def test_datetime_bounds_and_native_validation() raises:
    with assert_raises():
        _ = DateTimeValue(0, 1_000_000_000)
    with assert_raises():
        _ = DateTimeValue(59, 2_000_000_000)
    with assert_raises():
        _ = DateTimeValue.parse("0" * 65_537)
    with assert_raises():
        _ = FormulaNode("datetime", key="2023-02-29")
    with assert_raises():
        _ = FormulaNode("datetime_key", key="$score")
    var nodes: List[FormulaNode] = [FormulaNode("datetime", key="1970-01-01")]
    nodes[0].datetime.value().seconds = 9223372036854775807
    with assert_raises():
        _ = Formula(nodes^)


def test_datetime_reads_retained_payload_snapshot() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-datetime-"))
    var db = PersistentCollection.open(path, 1, maintenance_library_path="")
    var payload = json_value_from_python(PythonObject("1969-12-31T23:59:59.5Z"))
    db.upsert_document(1, [1], [DocumentField("created", payload^)])
    var view = db.snapshot()
    db.delete(1)
    db.close()
    var nodes: List[QueryNode] = [QueryNode("scroll"), QueryNode("formula", children=[0],
        formula=Optional(Formula([FormulaNode("datetime_key", key="created")])))]
    var hits = view.query(nodes, [])
    assert_equal(hits[0].id, 1)
    assert_equal(hits[0].score, Float64(-0.5))
    view.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
