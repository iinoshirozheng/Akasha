from akasha import PersistentCollection, DocumentField, PayloadValue
from akasha.document.json_reader import parse_json
from akasha.document.jsonb_reader import parse_jsonb
from akasha.query.jsonb_projection import JsonbProjection
from akasha.query.json_expression import JsonExpression
from akasha.query.json_snapshot import JsonIndexRequest
from akasha.index.lance_bitmap import LanceBitmapQuery, LanceBitmapBound
from akasha.index.lance_scalar import LanceScalarKey
from akasha.query.control import CancellationToken, QueryControl
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite


def _leaf(argument: String, value: Int64) raises -> JsonExpression:
    var spec = parse_json("{\"function\":\"json_get_int\",\"input\":\"data\",\"argument\":\"" + argument + "\"}")
    return JsonExpression(JsonbProjection(spec), LanceBitmapQuery.equals(LanceScalarKey.integer(value)))


def test_snapshot_owned_mixed_execution_survives_writes_and_close() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    collection.upsert_document(-7, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1,w:2}")))])
    collection.upsert_document(9, [0.0, 1.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:2,w:2}")))])
    var snapshot = collection.snapshot()
    var expression = JsonExpression.combine(1, [_leaf("v", 1), _leaf("w", 2)])
    var indexed = snapshot.prepare_json(expression.copy(), [JsonIndexRequest("data", "v")])
    var scan = snapshot.prepare_json(expression.copy(), [])
    assert_equal(indexed.indexed_leaf_count(), 1)
    assert_equal(indexed.execute(), scan.execute())
    assert_equal(indexed.execute(), [-7])
    collection.upsert_document(-7, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:3,w:2}")))])
    var later = collection.snapshot()
    var newer = later.prepare_json(expression.copy(), [JsonIndexRequest("data", "v")])
    assert_equal(len(newer.execute()), 0)
    snapshot.close()
    later.close()
    collection.close()
    assert_equal(indexed.execute(), [-7])
    assert_equal(scan.execute(), [-7])
    with assert_raises():
        _ = snapshot.prepare_json(expression.copy(), [])
    directory.cleanup()


def test_residual_errors_are_lazy() raises:
    var fields: List[DocumentField] = [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1,w:'bad'}")))]
    var conjunction = JsonExpression.combine(1, [_leaf("v", 0), _leaf("w", 2)])
    assert_equal(conjunction.evaluate(fields).value(), False)
    var disjunction = JsonExpression.combine(2, [_leaf("v", 1), _leaf("w", 2)])
    assert_equal(disjunction.evaluate(fields).value(), True)
    var reached = JsonExpression.combine(1, [_leaf("v", 1), _leaf("w", 2)])
    with assert_raises():
        _ = reached.evaluate(fields)


def _projection() raises -> JsonbProjection:
    return JsonbProjection(parse_json("""{"function":"json_get_int","input":"data","argument":"v"}"""))


def test_nullable_boolean_index_and_residual_matrix() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    for i in range(4):
        var body = "{v:" + String(i) + "}" if i < 3 else "{}"
        collection.upsert_document(i, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb(body)))])
    var snapshot = collection.snapshot()
    var leaves = List[JsonExpression]()
    leaves.append(_leaf("v", 1))
    leaves.append(JsonExpression(_projection(), LanceBitmapQuery.is_null()))
    leaves.append(JsonExpression(_projection(), LanceBitmapQuery.is_in([])))
    leaves.append(JsonExpression(_projection(), LanceBitmapQuery.is_in([LanceScalarKey.integer(2), LanceScalarKey.null(2)])))
    leaves.append(JsonExpression(_projection(), LanceBitmapQuery.equals(LanceScalarKey.null(2))))
    for a in range(len(leaves)):
        for b in range(len(leaves)):
            for kind in range(1, 3):
                var combined = JsonExpression.combine(UInt8(kind), [leaves[a].copy(), leaves[b].copy()])
                for negate in range(2):
                    var expression = combined.copy() if negate == 0 else JsonExpression.combine(3, [combined.copy()])
                    var indexed = snapshot.prepare_json(expression.copy(), [JsonIndexRequest("data", "v")])
                    var scan = snapshot.prepare_json(expression.copy(), [])
                    assert_equal(indexed.execute(), scan.execute())
    var empty_not = JsonExpression.combine(3, [leaves[2].copy()])
    assert_equal(snapshot.prepare_json(empty_not^, [JsonIndexRequest("data", "v")]).execute(), [0, 1, 2, 3])
    collection.close()
    directory.cleanup()


def test_compaction_deletion_cancellation_and_failed_preparation() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    collection.upsert_document(-1, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1,w:'bad'}")))])
    collection.upsert_document(2, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:2,w:'bad'}")))])
    collection.flush()
    var snapshot = collection.snapshot()
    var expression = JsonExpression.combine(2, [_leaf("v", 1), _leaf("v", 2)])
    var prepared = snapshot.prepare_json(expression.copy(), [JsonIndexRequest("data", "v")])
    var skip = JsonExpression.combine(2, [expression.copy(), _leaf("w", 4)])
    assert_equal(snapshot.prepare_json(skip^, [JsonIndexRequest("data", "v")]).execute(), [-1, 2])
    var fail = JsonExpression.combine(1, [expression.copy(), _leaf("w", 4)])
    var failing = snapshot.prepare_json(fail^, [JsonIndexRequest("data", "v")])
    with assert_raises():
        _ = failing.execute()
    with assert_raises():
        _ = snapshot.prepare_json(expression.copy(), [JsonIndexRequest("data", "w.x[")])
    var token = CancellationToken()
    var limit = QueryControl(token, max_candidates=1)
    with assert_raises():
        _ = prepared.execute(Optional(limit.copy()))
    with assert_raises():
        _ = snapshot.prepare_json(expression.copy(), [], control=Optional(limit.copy()))
    var control = QueryControl(token, max_candidates=100)
    token.cancel()
    with assert_raises():
        _ = prepared.execute(Optional(control.copy()))
    with assert_raises():
        _ = snapshot.prepare_json(expression.copy(), [], control=Optional(control.copy()))
    collection.delete(-1)
    collection.flush()
    collection.compact()
    var later = collection.snapshot()
    assert_equal(later.prepare_json(expression.copy(), [JsonIndexRequest("data", "v")]).execute(), [2])
    assert_equal(prepared.execute(), [-1, 2])
    snapshot.close()
    later.close()
    collection.close()
    var reopened = PersistentCollection.open(String(py=directory.name), 2)
    var recovered = reopened.snapshot()
    assert_equal(recovered.prepare_json(expression.copy(), [JsonIndexRequest("data", "v")]).execute(), [2])
    assert_equal(prepared.execute(), [-1, 2])
    reopened.close()
    directory.cleanup()


def test_binding_types_and_expression_bounds() raises:
    with assert_raises():
        _ = JsonExpression(_projection(), LanceBitmapQuery.equals(LanceScalarKey.text("1")))
    with assert_raises():
        _ = JsonExpression.combine(3, [])
    var expression = _leaf("v", 1)
    for _ in range(15):
        expression = JsonExpression.combine(3, [expression.copy()])
    with assert_raises():
        _ = JsonExpression.combine(3, [expression.copy()])
    var many = List[JsonExpression]()
    for _ in range(256):
        many.append(_leaf("v", 1))
    with assert_raises():
        _ = JsonExpression.combine(1, many)


def test_numeric_binding_ranges_and_custom_limits() raises:
    var fields: List[DocumentField] = [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:2.0}")))]
    var projection = JsonbProjection(parse_json("""{"function":"json_get_float","input":"data","argument":"v"}"""))
    var equality = JsonExpression(projection.copy(), LanceBitmapQuery.equals(LanceScalarKey.integer(2)))
    assert_equal(equality.evaluate(fields).value(), True)
    var range_query = LanceBitmapQuery.range_of(LanceBitmapBound(Optional(LanceScalarKey.integer(1)), False), LanceBitmapBound(Optional(LanceScalarKey.integer(2)), True))
    var between = JsonExpression(projection.copy(), range_query^)
    assert_equal(between.evaluate(fields).value(), True)
    assert_equal(JsonExpression.negate(between.copy()).evaluate(fields).value(), False)
    assert_equal(JsonExpression.all([equality.copy(), between.copy()]).evaluate(fields).value(), True)
    assert_equal(JsonExpression.any([]).evaluate(fields).value(), False)
    with assert_raises():
        _ = JsonExpression(_projection(), LanceBitmapQuery.equals(LanceScalarKey.float_bits(0)))
    with assert_raises():
        _ = JsonExpression(projection.copy(), LanceBitmapQuery.equals(LanceScalarKey.null(2)))
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    collection.upsert_document(1, [1.0, 0.0], fields^)
    var snapshot = collection.snapshot()
    var indexed = snapshot.prepare_json(between.copy(), [JsonIndexRequest("data", "v")])
    assert_equal(indexed.indexed_leaf_count(), 1)
    assert_equal(indexed.execute(), [1])
    var limited = JsonbProjection(parse_json("""{"function":"json_get_float","input":"data","argument":"v","max_work":1}"""))
    var residual = snapshot.prepare_json(JsonExpression(limited^, LanceBitmapQuery.is_null()), [JsonIndexRequest("data", "v")])
    assert_equal(residual.indexed_leaf_count(), 0)
    collection.close()
    directory.cleanup()


def test_extension_residual_and_nested_projection_do_not_hide_errors() raises:
    from akasha.document.jsonb import JsonbValue
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    var extension = JsonbValue.object([String("v")], [JsonbValue.date(0)])
    collection.upsert_document(1, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(extension^))])
    var snapshot = collection.snapshot()
    var text = JsonbProjection(parse_json("""{"function":"json_get_string","input":"data","argument":"v"}"""))
    var leaf = JsonExpression(text^, LanceBitmapQuery.is_null())
    var prepared = snapshot.prepare_json(leaf.copy(), [JsonIndexRequest("data", "v")])
    assert_equal(prepared.indexed_leaf_count(), 0)
    with assert_raises():
        _ = prepared.execute()
    var skipped = JsonExpression.any([JsonExpression.all([]), leaf.copy()])
    assert_equal(snapshot.prepare_json(skipped^, [JsonIndexRequest("data", "v")]).execute(), [1])
    var token = CancellationToken()
    var expired = QueryControl(token, max_candidates=100, deadline_ns=1)
    with assert_raises():
        _ = prepared.execute(Optional(expired.copy()))
    with assert_raises():
        _ = snapshot.prepare_json(leaf.copy(), [], control=Optional(expired.copy()))
    collection.upsert_document(2, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:2}")))])
    var mixed = collection.snapshot()
    with assert_raises():
        _ = mixed.prepare_json(leaf.copy(), [JsonIndexRequest("data", "v")])
    assert_equal(snapshot.prepare_json(JsonExpression.all([]), []).execute(), [1])
    collection.close()
    directory.cleanup()


def test_nested_projection_and_empty_snapshot() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    var empty = collection.snapshot()
    assert_equal(empty.prepare_json(JsonExpression.all([]), []).execute(), List[Int]())
    with assert_raises():
        _ = empty.prepare_json(JsonExpression.all([]), [JsonIndexRequest("data", "[")])
    collection.upsert_document(1, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1,nested:{v:2}}")))])
    var snapshot = collection.snapshot()
    var nested = JsonbProjection(parse_json("""{"function":"json_get_int","input":{"function":"json_get","input":"data","argument":"nested"},"argument":"v"}"""))
    var expression = JsonExpression.all([_leaf("v", 1), JsonExpression(nested^, LanceBitmapQuery.equals(LanceScalarKey.integer(2)))])
    var prepared = snapshot.prepare_json(expression.copy(), [JsonIndexRequest("data", "v")])
    assert_equal(prepared.indexed_leaf_count(), 1)
    assert_equal(prepared.execute(), [1])
    assert_equal(prepared.execute(), snapshot.prepare_json(expression.copy(), []).execute())
    assert_equal(empty.prepare_json(expression.copy(), []).execute(), List[Int]())
    collection.close()
    directory.cleanup()


def test_malformed_tree_rejected_before_execution() raises:
    var expression = JsonExpression.negate(_leaf("v", 1))
    expression._nodes[1].children[0] = 1
    with assert_raises():
        _ = expression.evaluate([])
    var detached = _leaf("v", 1)
    detached._nodes.append(detached._nodes[0].copy())
    with assert_raises():
        _ = detached.evaluate([])
    var wrong = _leaf("v", 1)
    wrong._nodes[0].target = 4
    with assert_raises():
        _ = wrong.evaluate([])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
