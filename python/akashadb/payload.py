"""Explicit JSONB carrier and JSON-safe typed payload transport.

Binary semantics, internal JSONB limits and persistence stay in Mojo. Ordinary
JSON dictionaries never opt into this transport by the names of their keys.
"""

from dataclasses import dataclass
import math
import re
from typing import Any


MAX_BYTES = 16 * 1024 * 1024
MAX_NODES = 65_536
MAX_DEPTH = 64
JSON_KINDS = frozenset({"string", "int", "uint", "float", "bool", "null", "array", "object"})


@dataclass(frozen=True, slots=True)
class JsonbValue:
    """Immutable source JSONB bytes; Mojo validates the body before any write.

    This carrier does not parse JSON text or implement binary JSONB in Python.
    """

    data: bytes

    def __post_init__(self) -> None:
        if type(self.data) is not bytes:
            raise TypeError("JSONB data must be immutable bytes")
        if len(self.data) > MAX_BYTES:
            raise ValueError("JSONB byte size exceeds limit")


class _Budget:
    def __init__(self) -> None:
        self.nodes = 0
        self.content = 0
        self.has_jsonb = False

    def value(self, depth: int, container: bool) -> None:
        self.nodes += 1
        if self.nodes > MAX_NODES:
            raise ValueError("payload node count exceeds limit")
        if depth > MAX_DEPTH or container and depth >= MAX_DEPTH:
            raise ValueError("payload nesting depth exceeds limit")

    def add_bytes(self, size: int) -> None:
        self.content += size
        if self.content > MAX_BYTES:
            raise ValueError("payload content exceeds size limit")


def _kind(value: Any) -> str:
    kind = type(value)
    if value is None:
        return "null"
    if kind is JsonbValue:
        return "jsonb"
    if kind is int:
        # Ordinary Python/JSON integers have no nested signedness label.
        # Only a field's explicit int/uint declaration carries that identity.
        return "integer"
    names = {str: "string", bool: "bool", float: "float", list: "array", dict: "object"}
    if kind not in names:
        raise ValueError("payload value must be JSON or JsonbValue")
    return names[kind]


def _scalar(kind: str, value: Any, budget: _Budget) -> Any:
    valid = False
    if kind == "null":
        valid = value is None
    elif kind == "string":
        valid = type(value) is str
        if valid:
            budget.add_bytes(len(value.encode("utf-8")))
    elif kind == "bool":
        valid = type(value) is bool
        budget.add_bytes(8)
    elif kind == "int":
        valid = type(value) is int and -(1 << 63) <= value < 1 << 63
        budget.add_bytes(8)
    elif kind == "integer":
        valid = type(value) is int and -(1 << 63) <= value < 1 << 64
        budget.add_bytes(8)
    elif kind == "uint":
        valid = type(value) is int and 0 <= value < 1 << 64
        budget.add_bytes(8)
    elif kind == "float":
        if type(value) in {int, float}:
            try:
                value = float(value)
            except OverflowError as error:
                raise ValueError("floating payload value exceeds Float64 range") from error
            valid = math.isfinite(value)
        budget.add_bytes(8)
    if not valid:
        raise ValueError("payload value does not match its declared type")
    return value


def _encode(value: Any, kind: str, budget: _Budget, depth: int) -> dict[str, Any]:
    budget.value(depth, kind in {"array", "object"})
    if kind == "jsonb":
        if type(value) is not JsonbValue:
            raise ValueError("jsonb payload requires JsonbValue")
        budget.add_bytes(len(value.data))
        budget.has_jsonb = True
        body = value.data.hex()
    elif kind == "array":
        if type(value) is not list:
            raise ValueError("array payload requires a list")
        body = [_encode(child, _kind(child), budget, depth + 1) for child in value]
    elif kind == "object":
        if type(value) is not dict:
            raise ValueError("object payload requires a dictionary")
        body = {}
        for key, child in value.items():
            if type(key) is not str:
                raise ValueError("payload object keys must be strings")
            budget.add_bytes(len(key.encode("utf-8")))
            body[key] = _encode(child, _kind(child), budget, depth + 1)
    else:
        body = _scalar(kind, value, budget)
    return {"type": kind, "value": body}


def encode_value(value: Any) -> dict[str, Any]:
    """Encode an explicitly typed wire value, including every container child."""
    return _encode(value, _kind(value), _Budget(), 0)


def _decode(node: Any, budget: _Budget, depth: int, *, field_root: bool = False) -> Any:
    if type(node) is not dict or set(node) != {"type", "value"} or type(node["type"]) is not str:
        raise ValueError("invalid typed payload value")
    kind, body = node["type"], node["value"]
    if kind in {"int", "uint"} and not field_root:
        raise ValueError("nested JSON integers use the integer wire tag")
    budget.value(depth, kind in {"array", "object"})
    if kind == "jsonb":
        if (type(body) is not str or len(body) > 2 * MAX_BYTES or len(body) % 2
                or re.fullmatch(r"[0-9a-fA-F]*", body) is None):
            raise ValueError("invalid JSONB hexadecimal data")
        budget.add_bytes(len(body) // 2)
        return JsonbValue(bytes.fromhex(body))
    if kind == "array":
        if type(body) is not list:
            raise ValueError("typed array payload requires a list")
        return [_decode(child, budget, depth + 1) for child in body]
    if kind == "object":
        if type(body) is not dict:
            raise ValueError("typed object payload requires a dictionary")
        result = {}
        for key, child in body.items():
            if type(key) is not str:
                raise ValueError("payload object keys must be strings")
            budget.add_bytes(len(key.encode("utf-8")))
            result[key] = _decode(child, budget, depth + 1)
        return result
    return _scalar(kind, body, budget)


def decode_value(node: Any) -> Any:
    """Decode only an explicitly selected typed wire representation."""
    return _decode(node, _Budget(), 0)


def encode_field(field: dict[str, Any], *, typed: bool = False) -> dict[str, Any]:
    if type(field["type"]) is not str or field["type"] not in JSON_KINDS | {"jsonb"}:
        raise ValueError("unknown payload field type")
    budget = _Budget()
    node = _encode(field["value"], field["type"], budget, 0)
    if typed or budget.has_jsonb:
        return {"name": field["name"], **node, "encoding": "typed"}
    return dict(field)


def decode_field(field: Any, *, require_typed: bool = False) -> dict[str, Any]:
    if type(field) is not dict:
        raise ValueError("invalid payload field")
    keys = {"name", "type", "value"}
    if set(field) == keys | {"encoding"} and field["encoding"] == "typed":
        if type(field["type"]) is not str or field["type"] not in JSON_KINDS | {"jsonb"}:
            raise ValueError("unknown payload field type")
        return {"name": field["name"], "type": field["type"],
                "value": _decode({"type": field["type"], "value": field["value"]}, _Budget(), 0, field_root=True)}
    if (require_typed or set(field) != keys or type(field["type"]) is not str
            or field["type"] not in JSON_KINDS):
        raise ValueError("invalid payload field encoding")
    return dict(field)


def decode_payload(values: Any) -> dict[str, Any]:
    """Decode typed values of a payload update with one shared resource budget."""
    if type(values) is not dict or len(values) > 1024:
        raise ValueError("payload update requires at most 1024 fields")
    budget = _Budget()
    result = {}
    for name, node in values.items():
        if type(name) is not str:
            raise ValueError("payload object keys must be strings")
        budget.add_bytes(len(name.encode("utf-8")))
        result[name] = _decode(node, budget, 0)
    return result
