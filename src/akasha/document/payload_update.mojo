"""Qdrant payload mutation semantics on Akasha's ordered document root.

Apache-2.0 source at 74f3e85b9473c62560006c043e13737ce6b48412:
lib/shard/src/update/payload.rs and segment/src/json_path/mod.rs.
The root map is not a nested Value, preserving the per-field depth contract.
"""
from akasha.document.record import DocumentField, clone_fields, validate_fields
from akasha.document.codec import encode_payload
from akasha.document.value import PayloadValue
from akasha.document.json_path import JsonPath
from akasha.document.payload_path import _value_set, _value_remove


def _slot(fields: List[DocumentField], name: String) -> Int:
    for i in range(len(fields)):
        if fields[i].name == name:
            return i
    return -1


def _remove_field(mut fields: List[DocumentField], index: Int):
    var last = fields.pop()
    if index < len(fields):
        fields[index] = last^


struct PayloadUpdate(Movable):
    """One payload-only operation; its result is committed by the collection."""
    var _kind: UInt8
    var _names: List[String]
    var _values: List[PayloadValue]
    var _path: Optional[JsonPath]
    var _keys: List[JsonPath]

    def __init__(out self, kind: UInt8, var names: List[String], var values: List[PayloadValue],
                 var path: Optional[JsonPath], var keys: List[JsonPath]) raises:
        if kind < 1 or kind > 4:
            raise Error("unknown payload update operation")
        if (kind != 1 and path) or (kind != 3 and len(keys) != 0):
            raise Error("payload update contains unrelated paths")
        if kind >= 3 and len(names) != 0:
            raise Error("payload delete/clear cannot contain values")
        if len(names) != len(values) or len(names) > 1024:
            raise Error("invalid payload update map size")
        if len(keys) > 1024:
            raise Error("payload deletion path count exceeds limit")
        var seen = Dict[String, Bool]()
        for name in names:
            if name in seen:
                raise Error("duplicate payload update key")
            seen[name] = True
        if path:
            var copied = List[PayloadValue]()
            for i in range(len(values)):
                copied.append(values[i].clone())
            _ = PayloadValue.object(names.copy(), copied^)
        else:
            var fields = List[DocumentField]()
            for i in range(len(names)):
                fields.append(DocumentField(names[i], values[i].clone()))
            _ = encode_payload(fields)
        self._kind = kind
        self._names = names^
        self._values = values^
        self._path = path^
        self._keys = keys^

    @staticmethod
    def set(var names: List[String], var values: List[PayloadValue],
            var path: Optional[JsonPath] = None) raises -> Self:
        return Self(1, names^, values^, path^, List[JsonPath]())

    @staticmethod
    def overwrite(var names: List[String], var values: List[PayloadValue]) raises -> Self:
        return Self(2, names^, values^, None, List[JsonPath]())

    @staticmethod
    def delete(var keys: List[JsonPath]) raises -> Self:
        return Self(3, List[String](), List[PayloadValue](), None, keys^)

    @staticmethod
    def clear() raises -> Self:
        return Self(4, List[String](), List[PayloadValue](), None, List[JsonPath]())

    def apply(self, fields: List[DocumentField]) raises -> List[DocumentField]:
        if self._kind == 2:
            var replacement = List[DocumentField]()
            for i in range(len(self._names)):
                replacement.append(DocumentField(self._names[i], self._values[i].clone()))
            return replacement^
        if self._kind == 4:
            return List[DocumentField]()
        var result = clone_fields(fields)
        if self._kind == 1 and self._path:
            var values = List[PayloadValue]()
            for i in range(len(self._values)):
                values.append(self._values[i].clone())
            var source = PayloadValue.object(self._names.copy(), values^)
            ref path = self._path.value()
            var index = _slot(result, path.first_key)
            var previous = result[index].value.clone() if index >= 0 else PayloadValue.null()
            var updated = _value_set(path.rest, 0, previous, source)
            if index >= 0:
                result[index].value = updated^
            else:
                result.append(DocumentField(path.first_key, updated^))
        elif self._kind == 1:
            for i in range(len(self._names)):
                var index = _slot(result, self._names[i])
                if self._values[i].is_null():
                    if index >= 0:
                        _remove_field(result, index)
                elif index >= 0:
                    result[index].value = self._values[i].clone()
                else:
                    result.append(DocumentField(self._names[i], self._values[i].clone()))
        else:
            for path in self._keys:
                var index = _slot(result, path.first_key)
                if index < 0:
                    continue
                if len(path.rest) == 0:
                    _remove_field(result, index)
                else:
                    var removed = List[PayloadValue]()
                    result[index].value = _value_remove(path.rest, 0, result[index].value, removed)
        validate_fields(result)
        return result^
