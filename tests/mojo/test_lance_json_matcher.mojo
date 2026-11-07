from akasha.index.lance_json_matcher import source_json_reference_type, json_bitmap_query_supported
from akasha.index.lance_json_stream import LanceJsonBitmapTrainer, LanceJsonBitmapIndex
from akasha.index.lance_bitmap import LanceBitmapQuery, LanceBitmapBound
from akasha.index.lance_scalar import LanceScalarKey
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_reader import parse_jsonb
from akasha.document.lance_json import LanceJson
from akasha.document.lance_json_result import evaluate_lance_json, lance_json_operation
from akasha.query.control import CancellationToken, QueryControl
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite
from test_lance_bitmap import _key


def _target(name: PythonObject) raises -> UInt8:
    var types: List[String] = ["Boolean", "Int64", "Float64", "Utf8", "LargeBinary"]
    for i in range(len(types)):
        if types[i] == String(py=name):
            return UInt8(i+1)
    raise Error("unknown source target")


def test_original_matching_and_actual_consumer_values() raises:
    var builtins = Python.import_module("builtins")
    var corpus = Python.import_module("json").loads(builtins.open("tests/fixtures/lance-json-matcher/cases.json").read())
    var covered = 0
    var mismatch = 0
    var built_count = 0
    var build_errors = 0
    for row in corpus:
        var bytes = List[UInt8]()
        for b in builtins.bytes.fromhex(row["body"]):
            bytes.append(UInt8(Int(py=b)))
        var body = JsonbValue(Span(bytes))
        var path = String(py=row["path"])
        var function = String(py=row["function"])
        var expected = row["result"]
        var reference = source_json_reference_type(path, function, Optional(path.copy()))
        if Bool(py=expected["reference_type"] == Python.none()):
            assert_false(Bool(reference))
        else:
            assert_equal(reference.value(), _target(expected["reference_type"]))
        var builder = LanceJsonBitmapTrainer(path.copy())
        var built = Optional[LanceJsonBitmapIndex]()
        var build_error = String()
        try:
            builder.push([Optional(body.clone())], [UInt64.MAX])
            built = Optional(builder.finish())
        except error:
            build_error = String(error)
        var expected_index = expected["indexed_value"]
        if built:
            assert_true(Bool(py=expected_index.__contains__("ok")))
            assert_equal(built.value().target(), _target(expected["index_type"]))
            built_count += 1
        else:
            assert_true(build_error.byte_length() > 0)
            if Bool(py=expected_index.__contains__("error")):
                assert_equal(build_error, String(py=expected_index["error"]))
            else:
                assert_true(Bool(py=expected_index.__contains__("panic")))
            build_errors += 1
        var consumer_target = UInt8(5) if function == "json_get" else UInt8(4) if function == "json_extract" else source_json_reference_type(path, function, Optional(path.copy())).value()
        var consumer = expected["consumer"]
        var rejected = False
        var matches = False
        var actual_key = Optional[LanceScalarKey]()
        if Bool(py=consumer.__contains__("panic")):
            with assert_raises():
                _ = evaluate_lance_json(LanceJson(body.clone()), lance_json_operation(function), path)
            rejected = True
        else:
            try:
                var actual = evaluate_lance_json(LanceJson(body.clone()), lance_json_operation(function), path)
                assert_true(Bool(py=consumer.__contains__("ok")))
                actual_key = Optional(LanceScalarKey.from_json_result(actual, consumer_target))
                assert_equal(actual_key.value().compare(_key(consumer["ok"], consumer_target)), 0)
            except error:
                rejected = True
                assert_true(Bool(py=consumer.__contains__("error")))
                assert_equal(String(error), String(py=consumer["error"]))
        if built:
            ref index = built.value()
            var key = _key(expected_index["ok"], index.target())
            assert_true(index._bitmap.lookup(key).contains(UInt64.MAX))
            if not rejected and consumer_target == index.target():
                matches = actual_key.value().compare(key) == 0
            var query = LanceBitmapQuery.is_null() if key.is_null else LanceBitmapQuery.equals(key.copy())
            var selection = index.try_search(function, Optional(path.copy()), query)
            if selection:
                assert_false(rejected)
                if not matches:
                    builtins.print("Unsafe matched reference", row, flush=True)
                assert_true(matches)
                assert_true(Bool(reference))
                assert_true(selection.value().selected(UInt64.MAX))
                covered += 1
            if Bool(reference) and not matches:
                mismatch += 1
    assert_equal(len(corpus), 1344)
    assert_equal(covered, 79)
    assert_equal(built_count, 1116)
    assert_equal(build_errors, 228)
    assert_true(mismatch > 0)


def test_path_and_stringification_counterexamples_are_declined() raises:
    var builder = LanceJsonBitmapTrainer("$.v")
    builder.push([Optional(parse_jsonb("{v:true,'$.v':false}"))], [1])
    var index = builder.finish()
    assert_equal(source_json_reference_type("$.v", "json_get_bool", Optional(String("$.v"))).value(), UInt8(1))
    assert_false(Bool(index.try_search("json_get_bool", Optional(String("$.v")), LanceBitmapQuery.equals(LanceScalarKey.boolean(True)))))
    var strings = LanceJsonBitmapTrainer("v")
    strings.push([Optional(parse_jsonb("{v:'abc'}"))], [1])
    var text = strings.finish()
    assert_false(Bool(text.try_search("json_extract", Optional(String("v")), LanceBitmapQuery.equals(LanceScalarKey.text("abc")))))
    assert_false(Bool(text.try_search("json_get_string", Optional(String("$.v")), LanceBitmapQuery.equals(LanceScalarKey.text("abc")))))
    assert_false(Bool(text.try_search("json_get_string", None, LanceBitmapQuery.is_null())))
    var numeric = LanceJsonBitmapTrainer("0")
    numeric.push([Optional(parse_jsonb("[true,false]"))], [1])
    var array_index = numeric.finish()
    assert_false(Bool(array_index.try_search("json_get_string", Optional(String("0")), LanceBitmapQuery.is_null())))


def test_source_null_predicate_rules_and_negated_unknowns() raises:
    var builder = LanceJsonBitmapTrainer("v")
    builder.push([Optional(parse_jsonb("{v:true}")), Optional(parse_jsonb("{v:false}")), None], [1, 2, 3])
    var index = builder.finish()
    var equals = LanceBitmapQuery.equals(LanceScalarKey.boolean(True))
    var not_equal = index.try_search("json_get_bool", Optional(String("v")), equals, negated=True)
    assert_true(Bool(not_equal))
    assert_false(not_equal.value().selected(1))
    assert_true(not_equal.value().selected(2))
    assert_false(not_equal.value().selected(3))
    assert_true(not_equal.value().rows.nulls.contains(3))
    var is_null = index.try_search("json_get_bool", Optional(String("v")), LanceBitmapQuery.is_null())
    assert_true(is_null.value().selected(3))
    assert_equal(is_null.value().rows.nulls.count(), 0)
    assert_false(json_bitmap_query_supported(1, LanceBitmapQuery.equals(LanceScalarKey.null(1))))
    assert_false(json_bitmap_query_supported(1, LanceBitmapQuery.is_in([LanceScalarKey.null(1)])))
    assert_false(json_bitmap_query_supported(1, LanceBitmapQuery.range_of(LanceBitmapBound(Optional(LanceScalarKey.null(1))), LanceBitmapBound())))
    assert_true(json_bitmap_query_supported(1, LanceBitmapQuery.is_in([])))
    assert_true(json_bitmap_query_supported(1, LanceBitmapQuery.range_of(LanceBitmapBound(), LanceBitmapBound())))
    assert_false(json_bitmap_query_supported(1, LanceBitmapQuery.equals(LanceScalarKey.integer(1))))
    assert_false(json_bitmap_query_supported(1, LanceBitmapQuery.full_text()))
    assert_false(json_bitmap_query_supported(1, LanceBitmapQuery.like_prefix(LanceScalarKey.text("a"))))
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=100)
    token.cancel()
    with assert_raises():
        _ = index.try_search("json_get_bool", Optional(String("v")), equals, control=Optional(control.copy()))
    with assert_raises():
        _ = index.try_search("json_extract", Optional(String("v")), equals, control=Optional(control.copy()))


def test_extension_string_provenance_survives_updates_and_remap() raises:
    var builder = LanceJsonBitmapTrainer("v")
    builder.push([Optional(parse_jsonb("{v:'abc'}"))], [1])
    var safe = builder.finish()
    var query = LanceBitmapQuery.is_null()
    assert_true(Bool(safe.try_search("json_get_string", Optional(String("v")), query)))
    var extension = JsonbValue.object([String("v")], [JsonbValue.date(0)])
    with assert_raises():
        _ = evaluate_lance_json(LanceJson(extension.clone()), lance_json_operation("json_get_string"), "v")
    var update = safe.trainer()
    update.push([Optional(extension.clone())], [2])
    var mixed = update.finish_update(safe)
    assert_false(Bool(mixed.try_search("json_get_string", Optional(String("v")), query)))
    assert_true(Bool(safe.try_search("json_get_string", Optional(String("v")), query)))
    var mapping = Dict[UInt64, Optional[UInt64]]()
    mapping[2] = None
    var removed = mixed.remapped(mapping)
    # Remap cannot recover the discarded original JSON types. Keep the marker
    # conservative; only a complete rebuild can prove all strings again.
    assert_false(Bool(removed.try_search("json_get_string", Optional(String("v")), query)))
    var rebuild = removed.trainer()
    rebuild.push([Optional(parse_jsonb("{v:'abc'}")), None], [1, 3])
    var rebuilt = rebuild.finish()
    assert_true(Bool(rebuilt.try_search("json_get_string", Optional(String("v")), query)))
    var additional = mixed.trainer()
    additional.push([Optional(parse_jsonb("{v:'more'}"))], [4])
    var still_mixed = additional.finish_update(mixed)
    assert_false(Bool(still_mixed.try_search("json_get_string", Optional(String("v")), query)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
