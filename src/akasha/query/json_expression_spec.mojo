"""Bounded public JSON expression binding; evaluation stays in the kernel."""
from std.memory import bitcast
from akasha.document.value import PayloadValue
from akasha.query.json_expression import JsonExpression
from akasha.query.jsonb_projection import JsonbProjection
from akasha.query.payload_condition import _known_keys, _required, _i64
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_bitmap import LanceBitmapQuery, LanceBitmapBound


def _hex(text: String) raises -> List[UInt8]:
    if text.byte_length() % 2 != 0 or text.byte_length() > 32 * 1024 * 1024:
        raise Error("invalid JSON literal hex length")
    var result = List[UInt8]()
    var high = UInt8(0)
    for i in range(text.byte_length()):
        var byte = text.as_bytes()[i]
        var digit: UInt8
        if byte >= 48 and byte <= 57:
            digit = byte - 48
        elif byte >= 97 and byte <= 102:
            digit = byte - 87
        elif byte >= 65 and byte <= 70:
            digit = byte - 55
        else:
            raise Error("invalid JSON literal hex digit")
        if i % 2 == 0:
            high = digit << 4
        else:
            result.append(high | digit)
    return result^


def _literal(value: PayloadValue, target: UInt8) raises -> LanceScalarKey:
    if value.is_null():
        return LanceScalarKey.null(target)
    if value.is_boolean():
        return LanceScalarKey.boolean(value.as_bool())
    if value.is_integer() or value.is_unsigned():
        var integer = _i64(value)
        if not integer:
            raise Error("JSON literal integer exceeds Int64")
        return LanceScalarKey.integer(integer.value())
    if value.is_floating():
        return LanceScalarKey.float_bits(bitcast[DType.uint64](value.as_float()))
    if value.is_string():
        return LanceScalarKey.text(value.as_string())
    _known_keys(value, ["float_bits", "binary"])
    var floating = value.get_key("float_bits")
    var binary = value.get_key("binary")
    if Bool(floating) == Bool(binary):
        raise Error("JSON literal requires exactly one typed value")
    if binary:
        return LanceScalarKey.binary(_hex(binary.value().as_string()))
    var bytes = _hex(floating.value().as_string())
    if len(bytes) != 8:
        raise Error("Float64 literal requires 16 hex digits")
    var bits = UInt64(0)
    for byte in bytes:
        bits = (bits << 8) | UInt64(byte)
    return LanceScalarKey.float_bits(bits)


def parse_json_expression(spec: PayloadValue) raises -> JsonExpression:
    var count = 0
    return _parse(spec, 1, count)


def _parse(spec: PayloadValue, depth: Int, mut count: Int) raises -> JsonExpression:
    count += 1
    if depth > 16 or count > 256:
        raise Error("JSON expression depth/node limit exceeded")
    var kind = _required(spec, "kind").as_string()
    if kind == "all" or kind == "any":
        _known_keys(spec, ["kind", "children"])
        var children = List[JsonExpression]()
        var raw = _required(spec, "children")
        if not raw.is_array():
            raise Error("JSON logical children require an array")
        var items = raw.children()
        for i in range(len(items)):
            children.append(_parse(items[i], depth+1, count))
        return JsonExpression.combine(UInt8(1 if kind == "all" else 2), children)
    if kind == "not":
        _known_keys(spec, ["kind", "child"])
        return JsonExpression.negate(_parse(_required(spec, "child"), depth+1, count))
    if kind != "predicate":
        raise Error("unknown JSON expression kind")
    var projection = JsonbProjection(_required(spec, "projection"))
    var op = projection.operation()
    var target = UInt8(4 if op == 0 or op == 1 or op == 5 else 5 if op == 4 else 2 if op == 6 or op == 10 else 3 if op == 7 else 1)
    var operator = _required(spec, "operator").as_string()
    var query: LanceBitmapQuery
    if operator == "is_null":
        _known_keys(spec, ["kind", "projection", "operator"])
        query = LanceBitmapQuery.is_null()
    elif operator == "in":
        _known_keys(spec, ["kind", "projection", "operator", "values"])
        var raw = _required(spec, "values")
        if not raw.is_array():
            raise Error("JSON IN requires an array")
        var values = List[LanceScalarKey]()
        var items = raw.children()
        for i in range(len(items)):
            values.append(_literal(items[i], target))
        query = LanceBitmapQuery.is_in(values^)
    elif operator == "between":
        _known_keys(spec, ["kind", "projection", "operator", "lower", "upper", "include_lower", "include_upper"])
        var low = LanceBitmapBound()
        var high = LanceBitmapBound()
        var lower = spec.get_key("lower")
        var upper = spec.get_key("upper")
        if lower:
            low.key = Optional(_literal(lower.value(), target))
        if upper:
            high.key = Optional(_literal(upper.value(), target))
        var included = spec.get_key("include_lower")
        if included:
            low.included = included.value().as_bool()
        included = spec.get_key("include_upper")
        if included:
            high.included = included.value().as_bool()
        query = LanceBitmapQuery.range_of(low^, high^)
    else:
        _known_keys(spec, ["kind", "projection", "operator", "value"])
        var literal = _literal(_required(spec, "value"), target)
        if operator == "eq" or operator == "ne":
            query = LanceBitmapQuery.equals(literal^)
        elif operator == "lt" or operator == "le":
            query = LanceBitmapQuery.range_of(LanceBitmapBound(), LanceBitmapBound(Optional(literal^), operator == "le"))
        elif operator == "gt" or operator == "ge":
            query = LanceBitmapQuery.range_of(LanceBitmapBound(Optional(literal^), operator == "ge"), LanceBitmapBound())
        else:
            raise Error("unknown JSON predicate operator")
    var result = JsonExpression(projection^, query^)
    return JsonExpression.negate(result^) if operator == "ne" else result^
