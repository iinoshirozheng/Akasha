from akasha.document.jsonb import JsonbValue
from akasha.document.lance_json import LanceJson, jsonb_get_by_name, jsonb_get_by_index, lance_json_type
from akasha.document.jsonb_reader import parse_jsonb
from akasha.query.control import QueryControl, CancellationToken
from std.memory import bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite


def _bytes(raw: PythonObject) raises -> List[UInt8]:
    var data = List[UInt8]()
    for byte in Python.import_module("builtins").bytes.fromhex(raw):
        data.append(UInt8(Int(py=byte)))
    return data^


def _hex(value: JsonbValue) raises -> PythonObject:
    var bytes = Python.list()
    for byte in value._data:
        bytes.append(Int(byte))
    return Python.import_module("builtins").bytes(bytes).hex()


def _result(value: LanceJson, op: Int, key: String, needle: String) raises -> PythonObject:
    if op == 0 or op == 1 or op == 5:
        var result = value.json_path(key) if op == 0 else (value.extract(key) if op == 1 else value.get_string(key))
        return PythonObject(result.value()) if result else Python.none()
    if op == 2:
        var result = value.extract_with_type(key)
        var out = Python.dict()
        out["value"] = _hex(result.value()[0]) if result else Python.none()
        out["type_tag"] = PythonObject(Int(result.value()[1]) if result else 0)
        return out
    if op == 3:
        return PythonObject(value.exists(key))
    if op == 4:
        var result = value.get(key)
        return _hex(result.value()) if result else Python.none()
    if op == 6 or op == 10:
        var result = value.get_int(key) if op == 6 else value.array_length(key)
        return PythonObject(result.value()) if result else Python.none()
    if op == 7:
        var result = value.get_float(key)
        if not result:
            return Python.none()
        return Python.import_module("builtins").format(PythonObject(bitcast[DType.uint64](result.value())), "016x")
    if op == 8:
        var result = value.get_bool(key)
        return PythonObject(result.value()) if result else Python.none()
    return PythonObject(value.array_contains(key, needle))


def test_original_lance_consumers() raises:
    var builtins = Python.import_module("builtins")
    var corpus = Python.import_module("json").loads(builtins.open("tests/fixtures/lance-json-functions/cases.json").read())
    var rows = 0
    var operations = 0
    for row in corpus:
        for operation in row["results"]:
            var op = Int(py=builtins.int(operation))
            var expected = row["results"][operation]
            var output = Python.list()
            var failed = False
            var message = String()
            try:
                for i in range(len(row["bodies"])):
                    var body = row["bodies"][i]
                    var arg = row["args"][0 if len(row["args"]) == 1 else i]
                    var needle = Python.none()
                    if op == 9:
                        needle = row["values"][0 if len(row["values"]) == 1 else i]
                    if body is Python.none() or arg is Python.none() or (op == 9 and needle is Python.none()):
                        if op == 2:
                            var result = Python.dict()
                            result["value"] = Python.none()
                            result["type_tag"] = PythonObject(0)
                            output.append(result)
                        else:
                            output.append(Python.none())
                        continue
                    var data = _bytes(body)
                    var value = LanceJson(JsonbValue(Span(data)))
                    output.append(_result(value, op, String(py=arg), String(py=needle) if op == 9 else String()))
            except error:
                failed = True
                message = String(error)
            try:
                if Bool(py=row.__contains__("input_limit")):
                    assert_true(failed)
                    assert_true(message.__contains__("nesting depth exceeds limit"))
                elif Bool(py=expected.__contains__("ok")):
                    assert_false(failed, message)
                    assert_true(Bool(py=output == expected["ok"]), String(py=output) + " != " + String(py=expected["ok"]))
                else:
                    assert_true(failed)
                    if Bool(py=expected.__contains__("error")):
                        assert_equal(message, String(py=expected["error"]))
            except error:
                print("Lance scenario", rows, "operation", op, "expected", expected, "native error", message)
                print("input", row["bodies"], row["args"])
                raise error
            operations += 1
        rows += 1
    assert_equal(rows, 47223)
    assert_equal(operations, 216337)


def test_distinct_consumers_and_owned_key_results() raises:
    var value = LanceJson(parse_jsonb("{a:[1,2],n:null,x:2.5,truth:'YES'}"))
    assert_equal(value.json_path("$.a[*]").value(), "1")
    assert_equal(value.extract("$.a[*]").value(), "[1,2]")
    assert_equal(value.get_int("x").value(), 3)
    assert_true(value.get_bool("truth").value())
    assert_false(Bool(value.get_string("n")))
    assert_equal(value.get("n").value().kind(), 5)
    assert_equal(value.array_length("$.x").value(), 0)
    assert_false(Bool(value.array_length("$.missing")))
    var got = value.get("a")
    value = LanceJson(parse_jsonb("null"))
    assert_equal(LanceJson(got.take()).get_int("+01").value(), 2)
    assert_false(Bool(jsonb_get_by_index(parse_jsonb("[1]"), UInt64.MAX)))
    assert_false(Bool(jsonb_get_by_name(parse_jsonb("{A:1}"), "a")))


def test_resource_limits_and_cancellation() raises:
    var value = parse_jsonb("{a:[1,2,3],b:'long string'}")
    with assert_raises():
        _ = LanceJson(value.clone(), max_work=1).get("b")
    with assert_raises():
        _ = LanceJson(value.clone(), max_bytes=1).get_string("b")
    with assert_raises():
        _ = LanceJson(value.clone(), max_results=1).extract("$.a[*]")
    with assert_raises():
        _ = LanceJson(value.clone(), max_bytes=4).extract("$.b")
    var elements = List[JsonbValue]()
    for i in range(100):
        elements.append(JsonbValue.integer(Int64(i)))
    var long_array = JsonbValue.array(elements)
    with assert_raises():
        _ = LanceJson(long_array.clone(), max_work=1000).array_length("$")
    with assert_raises():
        _ = LanceJson(long_array.clone(), max_work=1000).array_contains("$", "missing")
    assert_equal(LanceJson(long_array.clone(), max_work=6000).array_length("$").value(), 100)
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=100)
    var consumer = LanceJson(value.clone(), control=control.copy())
    token.cancel()
    with assert_raises():
        _ = consumer.get("a")
    with assert_raises():
        _ = consumer.array_contains("$.a", "1")
    with assert_raises():
        _ = LanceJson(value.clone(), max_work=0)
    with assert_raises():
        _ = LanceJson(value.clone(), control=QueryControl(CancellationToken(), max_candidates=100, deadline_ns=1)).array_length("$.a")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
