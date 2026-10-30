"""Bounded Python/JSON representation conversion; value ownership stays in Mojo."""
from akasha.document.value import PayloadValue
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_reader import parse_jsonb_bytes
from akasha.document.jsonb_writer import format_jsonb
from akasha.document.jsonb_path import JsonbPath
from akasha.document.jsonb_selector import JsonbSelector
from akasha.document.jsonb_cast import jsonb_to_bool, jsonb_to_i64, jsonb_to_u64, jsonb_to_f64, jsonb_to_str
from akasha.query.control import QueryControl, CancellationToken
from akasha.document.payload_update import PayloadUpdate
from akasha.document.json_path import JsonPath
from std.python import Python, PythonObject


def parse_jsonb_py(raw: PythonObject, standard: PythonObject) raises -> PythonObject:
    """Transport immutable UTF-8 bytes; all text interpretation stays in Mojo."""
    var builtins = Python.import_module("builtins")
    if not Bool(py=builtins.type(raw) == builtins.bytes):
        raise Error("JSONB text input must be immutable bytes")
    if not Bool(py=builtins.type(standard) == builtins.bool):
        raise Error("JSONB standard mode must be a bool")
    if len(raw) > JsonbValue.MAX_BYTES:
        raise Error("JSONB text exceeds byte limit")
    var bytes = List[UInt8](capacity=len(raw))
    for byte in raw:
        bytes.append(UInt8(Int(py=byte)))
    var value = parse_jsonb_bytes(Span(bytes), standard=Bool(py=standard))
    var output = List[PythonObject](capacity=len(value._data))
    for byte in value._data:
        output.append(PythonObject(Int(byte)))
    return builtins.bytes(Python.list(Span(output)))


def format_jsonb_py(raw: PythonObject, pretty: PythonObject) raises -> PythonObject:
    """Validate immutable source bytes and delegate all formatting to Mojo."""
    var builtins = Python.import_module("builtins")
    if not Bool(py=builtins.type(raw) == builtins.bytes):
        raise Error("JSONB formatting input must be immutable bytes")
    if not Bool(py=builtins.type(pretty) == builtins.bool):
        raise Error("JSONB pretty mode must be a bool")
    if len(raw) > JsonbValue.MAX_BYTES:
        raise Error("JSONB byte size exceeds limit")
    var bytes = List[UInt8](capacity=len(raw))
    for byte in raw:
        bytes.append(UInt8(Int(py=byte)))
    var value = JsonbValue(Span(bytes))
    return PythonObject(format_jsonb(value, pretty=Bool(py=pretty)))


def _jsonb_bytes(value: JsonbValue) raises -> PythonObject:
    var builtins = Python.import_module("builtins")
    var bytes = List[PythonObject](capacity=len(value._data))
    for byte in value._data:
        bytes.append(PythonObject(Int(byte)))
    return builtins.bytes(Python.list(Span(bytes)))


def cast_jsonb_py(raw: PythonObject, target: PythonObject) raises -> PythonObject:
    var builtins = Python.import_module("builtins")
    if not Bool(py=builtins.type(raw) == builtins.bytes) or not Bool(py=builtins.type(target) == builtins.int):
        raise Error("JSONB cast requires immutable bytes and an integer target")
    var mode = Int(py=target)
    if mode < 0 or mode > 4:
        raise Error("unknown JSONB cast target")
    if len(raw) > JsonbValue.MAX_BYTES:
        raise Error("JSONB cast input exceeds byte resource limit")
    var bytes = List[UInt8](capacity=len(raw))
    for byte in raw:
        bytes.append(UInt8(Int(py=byte)))
    var value = JsonbValue(Span(bytes))
    if mode == 0:
        return PythonObject(jsonb_to_bool(value))
    if mode == 1:
        return PythonObject(jsonb_to_i64(value))
    if mode == 2:
        return PythonObject(jsonb_to_u64(value))
    if mode == 3:
        return PythonObject(jsonb_to_f64(value))
    return PythonObject(jsonb_to_str(value))


def query_jsonb_py(raw: PythonObject, raw_path: PythonObject, mode: PythonObject, options: PythonObject) raises -> PythonObject:
    """Thin byte/options boundary; parsing, selection and arithmetic are native."""
    var builtins = Python.import_module("builtins")
    if not Bool(py=builtins.type(raw) == builtins.bytes) or not Bool(py=builtins.type(raw_path) == builtins.bytes):
        raise Error("JSONB body and query path must be immutable bytes")
    if len(raw) > JsonbValue.MAX_BYTES or len(raw_path) > JsonbPath.MAX_BYTES:
        raise Error("JSONB query input exceeds byte resource limit")
    if not Bool(py=builtins.type(mode) == builtins.int) or not Bool(py=builtins.type(options) == builtins.dict):
        raise Error("JSONB query requires an integer mode and options dictionary")
    var selected_mode = Int(py=mode)
    if selected_mode < 0 or selected_mode > 5:
        raise Error("unknown JSONB query mode")
    for key in ["max_work", "max_results", "max_bytes", "deadline_ns"]:
        if not Bool(py=builtins.type(options[PythonObject(key)]) == builtins.int):
            raise Error("JSONB query limits and deadline must be integers")
    if not Bool(py=builtins.type(options["cancelled"]) == builtins.bool):
        raise Error("JSONB query cancellation must be a bool")
    var token = CancellationToken()
    if Bool(py=options["cancelled"]):
        token.cancel()
    var max_work = Int(py=options["max_work"])
    var control = QueryControl(token, max_candidates=max_work, deadline_ns=Int(py=options["deadline_ns"]))
    control.checkpoint(0)
    var bytes = List[UInt8](capacity=len(raw))
    for byte in raw:
        bytes.append(UInt8(Int(py=byte)))
    var path_bytes = List[UInt8](capacity=len(raw_path))
    for byte in raw_path:
        path_bytes.append(UInt8(Int(py=byte)))
    var path = JsonbPath.parse_bytes(Span(path_bytes))
    var selector = JsonbSelector(JsonbValue(Span(bytes)), max_work=max_work,
        max_results=Int(py=options["max_results"]), max_bytes=Int(py=options["max_bytes"]), control=control^)
    if selected_mode == 0:
        var values = selector.select_values(path)
        var output = Python.list()
        for value in values:
            output.append(_jsonb_bytes(value))
        return output
    if selected_mode == 1:
        return _jsonb_bytes(selector.select_array(path))
    if selected_mode == 2 or selected_mode == 3:
        var value = selector.select_first(path) if selected_mode == 2 else selector.select_value(path)
        if not value:
            return Python.none()
        return _jsonb_bytes(value.value())
    if selected_mode == 4:
        return PythonObject(selector.exists(path))
    var value = selector.predicate_match(path)
    return PythonObject(value.value()) if value else Python.none()


def json_value_from_python(raw: PythonObject) raises -> PayloadValue:
    var nodes = 0
    var content = 0
    return _json_value(raw, 0, nodes, content)


def payload_update_from_python(kind: String, raw: PythonObject,
                               key: PythonObject, raw_keys: PythonObject) raises -> PayloadUpdate:
    var builtins = Python.import_module("builtins")
    var path = Optional[JsonPath]()
    if not (key is Python.none()):
        if not Bool(py=builtins.type(key) == builtins.str):
            raise Error("payload path must be a string")
        path = Optional(JsonPath.parse(String(py=key)))
    var paths = List[JsonPath]()
    if not Bool(py=builtins.isinstance(raw_keys, builtins.list)):
        raise Error("payload deletion paths must be a list")
    if len(raw_keys) > 1024:
        raise Error("payload deletion path count exceeds limit")
    for item in raw_keys:
        if len(paths) == 1024:
            raise Error("payload deletion path count exceeds limit")
        if not Bool(py=builtins.type(item) == builtins.str):
            raise Error("payload deletion paths must be strings")
        paths.append(JsonPath.parse(String(py=item)))
    var names = List[String]()
    var values = List[PayloadValue]()
    if kind == "set" or kind == "overwrite":
        if not Bool(py=builtins.type(raw) == builtins.dict):
            raise Error("payload update requires a JSON object")
        if len(raw) > 1024:
            raise Error("payload update field count exceeds limit")
        var nodes = 0
        var content = 0
        for name in raw:
            if not Bool(py=builtins.type(name) == builtins.str):
                raise Error("payload object keys must be strings")
            var converted = String(py=name)
            content += converted.byte_length()
            if content > PayloadValue.MAX_BYTES:
                raise Error("payload content exceeds size limit")
            names.append(converted^)
            values.append(_json_value(raw[name], 0, nodes, content, True))
    elif not (raw is Python.none()):
        raise Error("payload delete/clear cannot contain values")
    var operation: UInt8
    if kind == "set":
        operation = 1
    elif kind == "overwrite":
        operation = 2
    elif kind == "delete":
        operation = 3
    elif kind == "clear":
        operation = 4
    else:
        raise Error("unknown payload update operation")
    return PayloadUpdate(operation, names^, values^, path^, paths^)


def _json_value(raw: PythonObject, depth: Int, mut nodes: Int, mut content: Int,
                allow_jsonb: Bool = False) raises -> PayloadValue:
    nodes += 1
    if nodes > PayloadValue.MAX_NODES:
        raise Error("payload node count exceeds limit")
    var builtins = Python.import_module("builtins")
    var kind = builtins.type(raw)
    if allow_jsonb and Bool(py=kind == Python.import_module("akashadb.payload").JsonbValue):
        var data = raw.data
        if not Bool(py=builtins.type(data) == builtins.bytes):
            raise Error("JSONB data must be immutable bytes")
        if len(data) > PayloadValue.MAX_BYTES - content:
            raise Error("payload content exceeds size limit")
        var bytes = List[UInt8](capacity=len(data))
        for byte in data:
            bytes.append(UInt8(Int(py=byte)))
        var value = JsonbValue(Span(bytes))
        nodes += value._node_count - 1
        content += len(bytes)
        if nodes > PayloadValue.MAX_NODES:
            raise Error("payload node count exceeds limit")
        if depth + value._depth > PayloadValue.MAX_DEPTH:
            raise Error("payload nesting depth exceeds limit")
        return PayloadValue.jsonb(value^)
    if raw is Python.none():
        return PayloadValue.null()
    if Bool(py=kind == builtins.str):
        if len(raw) > PayloadValue.MAX_BYTES - content:
            raise Error("payload content exceeds size limit")
        var text = String(py=raw)
        content += text.byte_length()
        if content > PayloadValue.MAX_BYTES:
            raise Error("payload content exceeds size limit")
        return PayloadValue.string(text)
    if Bool(py=kind == builtins.bool):
        content += 8
        return PayloadValue.boolean(Bool(py=raw))
    if Bool(py=kind == builtins.int):
        content += 8
        if Bool(py=raw < PythonObject(Int64.MIN)) or Bool(py=raw > PythonObject(UInt64.MAX)):
            raise Error("JSON integer exceeds Int64/UInt64 range")
        if Bool(py=raw > PythonObject(Int64.MAX)):
            # Mojo 1.0's Scalar(py=...) passes through signed Py_ssize_t.
            # Split the validated Python integer at the serialization boundary.
            var high = UInt64(Int(py=raw.__rshift__(32)))
            var low = UInt64(Int(py=raw.__and__(0xFFFFFFFF)))
            return PayloadValue.unsigned((high << 32) | low)
        return PayloadValue.integer(Int64(py=raw))
    if Bool(py=kind == builtins.float):
        content += 8
        return PayloadValue.floating(Float64(py=raw))
    var object = Bool(py=kind == builtins.dict)
    if not object and not Bool(py=kind == builtins.list):
        raise Error("payload value must be a JSON value")
    if depth >= PayloadValue.MAX_DEPTH:
        raise Error("payload nesting depth exceeds limit")
    if len(raw) > PayloadValue.MAX_NODES - nodes:
        raise Error("payload node count exceeds limit")
    var keys = List[String]()
    var values = List[PayloadValue]()
    for entry in raw:
        if object:
            if not Bool(py=builtins.type(entry) == builtins.str):
                raise Error("payload object keys must be strings")
            if len(entry) > PayloadValue.MAX_BYTES - content:
                raise Error("payload content exceeds size limit")
            var key = String(py=entry)
            content += key.byte_length()
            if content > PayloadValue.MAX_BYTES:
                raise Error("payload content exceeds size limit")
            keys.append(key^)
            values.append(_json_value(raw[entry], depth + 1, nodes, content, allow_jsonb))
        else:
            values.append(_json_value(entry, depth + 1, nodes, content, allow_jsonb))
        if content > PayloadValue.MAX_BYTES:
            raise Error("payload content exceeds size limit")
    if object:
        return PayloadValue.object(keys^, values^)
    return PayloadValue.array(values^)


def payload_value_from_python(kind: String, raw: PythonObject) raises -> PayloadValue:
    # Explicit scalar fields retain their established Python conversion protocol.
    # Container contents use strict JSON kinds because they have no declared type.
    if kind == "string":
        return PayloadValue.string(String(py=raw))
    if kind == "int":
        return PayloadValue.integer(Int64(py=raw))
    if kind == "float":
        return PayloadValue.floating(Float64(py=raw))
    if kind == "bool":
        return PayloadValue.boolean(Bool(py=raw))
    var nodes = 0
    var content = 0
    var value = _json_value(raw, 0, nodes, content, True)
    if ((kind == "null" and value.is_null()) or (kind == "array" and value.is_array())
        or (kind == "object" and value.is_object()) or (kind == "uint" and value.is_unsigned())
        or (kind == "jsonb" and value.is_jsonb())):
        return value^
    if kind == "uint" and value.is_integer() and value.as_int() >= 0:
        return PayloadValue.unsigned(UInt64(value.as_int()))
    raise Error("payload value does not match its declared type")


def payload_kind_name(value: PayloadValue) raises -> String:
    if value.is_string():
        return "string"
    if value.is_integer():
        return "int"
    if value.is_floating():
        return "float"
    if value.is_boolean():
        return "bool"
    if value.is_null():
        return "null"
    if value.is_array():
        return "array"
    if value.is_object():
        return "object"
    if value.is_unsigned():
        return "uint"
    if value.is_jsonb():
        return "jsonb"
    raise Error("unknown payload value kind")


def payload_value_to_python(value: PayloadValue) raises -> PythonObject:
    if value.is_string():
        return PythonObject(value.as_string())
    if value.is_integer():
        return PythonObject(value.as_int())
    if value.is_floating():
        return PythonObject(value.as_float())
    if value.is_boolean():
        return PythonObject(value.as_bool())
    if value.is_unsigned():
        return PythonObject(value.as_uint())
    if value.is_null():
        return Python.none()
    if value.is_jsonb():
        var bytes = Python.list()
        for byte in value._jsonb_value.value()._data:
            bytes.append(PythonObject(Int(byte)))
        return Python.import_module("akashadb.payload").JsonbValue(Python.import_module("builtins").bytes(bytes))
    var children = value.children()
    if value.is_array():
        var result = Python.list()
        for i in range(len(children)):
            result.append(payload_value_to_python(children[i]))
        return result
    var keys = value.keys()
    var result = Python.dict()
    for i in range(len(children)):
        result[PythonObject(keys[i])] = payload_value_to_python(children[i])
    return result
