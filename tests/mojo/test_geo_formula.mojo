from akasha.document.geo import GeoPoint, haversine_distance
from akasha.document.record import DocumentField
from akasha.query.formula import Formula, FormulaDefault, FormulaNode
from akasha.query.query_plan import QueryNode
from akasha.api.collection import PersistentCollection
from bindings.payload_python import json_value_from_python
from test_formula import _fixture_expression
from std.memory import bitcast
from std.math import inf, isfinite, nan
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_false, assert_raises, TestSuite


def fixture() raises -> PythonObject:
    return Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-geo/geo.json").read())


def test_geo_point_matches_qdrant_serde_validation() raises:
    var rows = fixture()["points"]
    for i in range(len(rows)):
        var row = rows[i]
        var value = json_value_from_python(row["input"])
        if Bool(py=row.__contains__("error")):
            with assert_raises():
                _ = GeoPoint.from_payload(value)
        else:
            var actual = GeoPoint.from_payload(value)
            assert_equal(bitcast[DType.uint64](actual.lon), bitcast[DType.uint64](Float64(py=row["point"][0])))
            assert_equal(bitcast[DType.uint64](actual.lat), bitcast[DType.uint64](Float64(py=row["point"][1])))
    for raw in [inf[DType.float64](), -inf[DType.float64](), nan[DType.float64]()]:
        with assert_raises():
            _ = GeoPoint(raw, 0)
        with assert_raises():
            _ = GeoPoint(0, raw)


def test_haversine_matches_actual_geo_dependency() raises:
    var rows = fixture()["distances"]
    for i in range(len(rows)):
        var a = json_value_from_python(rows[i]["from"])
        var b = json_value_from_python(rows[i]["to"])
        var actual = haversine_distance(GeoPoint.from_payload(a), GeoPoint.from_payload(b))
        if Bool(py=rows[i]["finite"]):
            assert_equal(bitcast[DType.uint64](actual), UInt64(Int(py=rows[i]["bits"])), "geo distance " + String(i))
        else:
            assert_false(isfinite(actual), "geo nonfinite distance " + String(i))


def test_geo_formula_matches_qdrant_scorer_and_retrieval() raises:
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
        var first = Dict[Int, Float32]()
        first[1] = 0
        var scores: List[Dict[Int, Float32]] = [first^]
        if row["expected_bits"] is Python.none():
            with assert_raises():
                _ = formula.score(1, fields, scores)
        else:
            assert_equal(bitcast[DType.uint32](formula.score(1, fields, scores)),
                UInt32(Int(py=row["expected_bits"])), "geo formula " + String(i))


def test_geo_formula_snapshot_and_native_validation() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-geo-formula-"))
    var db = PersistentCollection.open(path, 1, maintenance_library_path="")
    var raw = Python.import_module("json").loads('{"point": {"lat": 0, "lon": 0}}')
    db.upsert_document(1, [1], [DocumentField("meta", json_value_from_python(raw))])
    var view = db.snapshot()
    db.delete(1)
    db.close()
    var nodes: List[QueryNode] = [QueryNode("scroll"), QueryNode("formula", children=[0],
        formula=Optional(Formula([FormulaNode("geo_distance", key="meta.point", origin=Optional(GeoPoint(0, 0)))])))]
    var hits = view.query(nodes, [])
    assert_equal(hits[0].score, Float64(0))
    view.close()
    Python.import_module("shutil").rmtree(path)
    with assert_raises():
        _ = Formula([FormulaNode("geo_distance", key="location")])
    with assert_raises():
        _ = FormulaNode("geo_distance", key="$score", origin=Optional(GeoPoint(0, 0)))
    var invalid = GeoPoint(0, 0)
    invalid.lat = 91
    with assert_raises():
        _ = Formula([FormulaNode("geo_distance", key="location", origin=Optional(invalid^))])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
