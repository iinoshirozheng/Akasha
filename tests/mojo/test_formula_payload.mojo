from akasha.query.formula import Formula, FormulaDefault, FormulaNode
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.api.collection import PersistentCollection
from akasha.query.query_plan import QueryNode
from bindings.payload_python import json_value_from_python
from test_formula import _fixture_expression
from std.python import Python
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def test_rich_formula_matches_original_payload_retriever_and_scorer() raises:
    var builtins = Python.import_module("builtins")
    var cases = Python.import_module("json").loads(builtins.open(
        "tests/fixtures/qdrant-formula-payload/formula.json").read())["cases"]
    for i in range(len(cases)):
        var row = cases[i]
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
                UInt32(Int(py=row["expected_bits"])), "rich formula source case " + String(i))


def test_rich_formula_keeps_full_field_depth_and_default_limits() raises:
    var value = PayloadValue.unsigned(UInt64.MAX)
    var path = String("a")
    for _ in range(64):
        value = PayloadValue.array([value^])
        path += "[0]"
    var formula = Formula([FormulaNode("variable", key=path)])
    var fields: List[DocumentField] = [DocumentField("a", value^)]
    assert_equal(formula.score(1, fields, []), Float32(UInt64.MAX))
    var defaults = List[FormulaDefault]()
    var many = List[PayloadValue]()
    for _ in range(32767):
        many.append(PayloadValue.null())
    var array = PayloadValue.array(many^)
    defaults.append(FormulaDefault("a", array.clone()))
    defaults.append(FormulaDefault("b", array.clone()))
    var accepted = Formula([FormulaNode("constant", value=1)], defaults^)
    assert_equal(accepted.score(1, [], []), Float32(1))
    accepted.defaults.append(FormulaDefault("c", PayloadValue.null()))
    with assert_raises():
        accepted.validate()


def test_rich_formula_reads_retained_snapshot_after_mutation_and_close() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-formula-payload-"))
    var db = PersistentCollection.open(path, 1, maintenance_library_path="")
    var raw = Python.import_module("json").loads('{"weight": [3]}')
    db.upsert_document(1, [1], [DocumentField("meta", json_value_from_python(raw))])
    var view = db.snapshot()
    db.upsert_document(1, [1], [DocumentField("meta", PayloadValue.null())])
    db.close()
    var nodes: List[QueryNode] = [QueryNode("scroll"), QueryNode("formula", children=[0],
        formula=Optional(Formula([FormulaNode("variable", key="meta.weight")])))]
    var hits = view.query(nodes, [])
    assert_equal(hits[0].id, 1)
    assert_equal(hits[0].score, Float64(3))
    var reopened = PersistentCollection.open(path, 1, maintenance_library_path="")
    with assert_raises():
        _ = reopened.query(nodes, [])
    reopened.close()
    view.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
