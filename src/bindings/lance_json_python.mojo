"""Nullable Arrow/scalar transport for the native Lance JSON consumers."""
from std.python import Python, PythonObject
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_path import JsonbPath
from akasha.document.lance_json import LanceJson
from akasha.query.control import QueryControl, CancellationToken
from bindings.payload_python import _jsonb_bytes


def _null(op: Int) raises -> PythonObject:
    if op != 2:
        return Python.none()
    var result = Python.dict()
    result["value"] = Python.none()
    result["type_tag"] = PythonObject(0)
    return result


def _result(value: LanceJson, op: Int, key: String, needle: String) raises -> PythonObject:
    if op == 0 or op == 1 or op == 5:
        var result = value.json_path(key) if op == 0 else (value.extract(key) if op == 1 else value.get_string(key))
        return PythonObject(result.value()) if result else Python.none()
    if op == 2:
        var result = value.extract_with_type(key)
        var out = _null(op)
        if result:
            out["value"] = _jsonb_bytes(result.value()[0])
            out["type_tag"] = PythonObject(Int(result.value()[1]))
        return out
    if op == 3:
        return PythonObject(value.exists(key))
    if op == 4:
        var result = value.get(key)
        return _jsonb_bytes(result.value()) if result else Python.none()
    if op == 6 or op == 10:
        var result = value.get_int(key) if op == 6 else value.array_length(key)
        return PythonObject(result.value()) if result else Python.none()
    if op == 7:
        var result = value.get_float(key)
        return PythonObject(result.value()) if result else Python.none()
    if op == 8:
        var result = value.get_bool(key)
        return PythonObject(result.value()) if result else Python.none()
    return PythonObject(value.array_contains(key, needle))


def lance_json_py(bodies: PythonObject, args: PythonObject, needles: PythonObject,
                  operation: PythonObject, options: PythonObject) raises -> PythonObject:
    var builtins = Python.import_module("builtins")
    if not Bool(py=builtins.type(operation) == builtins.int) or not Bool(py=builtins.type(options) == builtins.dict):
        raise Error("Lance JSON requires an integer operation and options dictionary")
    var op = Int(py=operation)
    if op < 0 or op > 10:
        raise Error("unknown Lance JSON operation")
    for key in ["max_work", "max_results", "max_bytes", "deadline_ns"]:
        if not Bool(py=builtins.type(options[PythonObject(key)]) == builtins.int):
            raise Error("Lance JSON limits and deadline must be integers")
    if not Bool(py=builtins.type(options["cancelled"]) == builtins.bool):
        raise Error("Lance JSON cancellation must be a bool")
    var max_work = Int(py=options["max_work"])
    var max_results = Int(py=options["max_results"])
    var max_bytes = Int(py=options["max_bytes"])
    if max_work <= 0 or max_results <= 0 or max_bytes <= 0:
        raise Error("Lance JSON resource limits must be positive")
    var token = CancellationToken()
    if Bool(py=options["cancelled"]):
        token.cancel()
    var control = QueryControl(token, max_candidates=max_work, deadline_ns=Int(py=options["deadline_ns"]))
    control.checkpoint(0)
    for items in [bodies, args, needles]:
        if not Bool(py=builtins.type(items) == builtins.list):
            raise Error("Lance JSON transport requires lists")
        if len(items) > 65_536:
            raise Error("Lance JSON row resource limit exceeded")
    var rows = len(bodies)
    if rows > max_results or rows > 65_536:
        raise Error("Lance JSON row resource limit exceeded")
    if len(args) != 1 and len(args) < rows:
        raise Error("Lance JSON argument must broadcast or cover every row")
    if op == 9 and len(needles) != 1 and len(needles) < rows:
        raise Error("Lance JSON contains value must broadcast or cover every row")
    var input_bytes = 0
    for body in bodies:
        if body is Python.none():
            continue
        if not Bool(py=builtins.type(body) == builtins.bytes):
            raise Error("Lance JSON body must be immutable bytes or null")
        if len(body) > JsonbValue.MAX_BYTES or len(body) > max_bytes - input_bytes:
            raise Error("Lance JSON input byte resource limit exceeded")
        input_bytes += len(body)
    for items in [args, needles]:
        for item in items:
            if item is Python.none():
                continue
            if not Bool(py=builtins.type(item) == builtins.str):
                raise Error("Lance JSON argument must be a string or null")
            if len(item) > JsonbPath.MAX_BYTES:
                raise Error("Lance JSON argument byte resource limit exceeded")
            var text = String(py=item)
            if text.byte_length() > JsonbPath.MAX_BYTES or text.byte_length() > max_bytes - input_bytes:
                raise Error("Lance JSON argument byte resource limit exceeded")
            input_bytes += text.byte_length()
    var output = Python.list()
    var output_bytes = 0
    for i in range(rows):
        control.checkpoint(0)
        var body = bodies[i]
        var key = args[0 if len(args) == 1 else i]
        var needle = Python.none()
        if op == 9:
            needle = needles[0 if len(needles) == 1 else i]
        # Source Arrow short-circuit: no decode/path parsing for a null row.
        if body is Python.none() or key is Python.none() or (op == 9 and needle is Python.none()):
            if 8 > max_bytes - output_bytes:
                raise Error("Lance JSON output byte resource limit exceeded")
            output_bytes += 8
            output.append(_null(op))
            continue
        var data = List[UInt8](capacity=len(body))
        for byte in body:
            data.append(UInt8(Int(py=byte)))
        var value = LanceJson(JsonbValue(Span(data)), max_work=max_work,
                              max_results=max_results, max_bytes=max_bytes, control=control.copy())
        var result = _result(value, op, String(py=key), String(py=needle) if op == 9 else String())
        var size = 8
        if not (result is Python.none()):
            if op == 2:
                if not (result["value"] is Python.none()):
                    size += len(result["value"])
            elif op == 4:
                size += len(result)
            elif op == 0 or op == 1 or op == 5:
                size += String(py=result).byte_length()
        if size > max_bytes - output_bytes:
            raise Error("Lance JSON output byte resource limit exceeded")
        output_bytes += size
        output.append(result)
    return output
