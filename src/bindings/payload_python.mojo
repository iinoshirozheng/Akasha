"""Bounded Python/JSON representation conversion; value ownership stays in Mojo."""
from akasha.document.value import PayloadValue
from akasha.document.jsonb import JsonbValue
from akasha.document.payload_update import PayloadUpdate
from akasha.document.json_path import JsonPath
from std.python import Python, PythonObject


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
