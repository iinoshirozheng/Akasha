"""jsonb 0.5.6 RawJsonb scalar casts (Datafuse Labs, Apache-2.0).

String integer parsing follows Rust 1.92 core num::from_ascii_radix's checked
decimal accumulation (Rust contributors, MIT). The existing source fast-float
port supplies float parsing; differential fixtures execute Rust str::parse.
These casts differ from exact typed binary getters and JSON serialization.
"""
from std.memory import bitcast
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_number import JsonbNumber
from akasha.document.jsonb_display import format_jsonb_number_display
from akasha.document.fast_float import parse_fast_float


def _numeric(value: JsonbValue) -> Bool:
    var kind = value.kind()
    return kind == 2 or kind == 3 or kind == 8 or kind == 9


def _parse_integer(text: String, signed: Bool) -> Optional[UInt64]:
    # Rust FromStr/from_ascii_radix radix 10, using a widened checked
    # accumulator for the signed/unsigned 64-bit target. No whitespace trim.
    var bytes = text.as_bytes()
    if len(bytes) == 0:
        return None
    var position = 0
    var positive = True
    if bytes[0] == 43:
        position = 1
    elif signed and bytes[0] == 45:
        positive = False
        position = 1
    if position == len(bytes):
        return None
    var minimum = Int128(Int64.MIN) if signed else Int128(0)
    var maximum = Int128(Int64.MAX) if signed else Int128(UInt64.MAX)
    var value = Int128(0)
    while position < len(bytes):
        var byte = bytes[position]
        if byte < 48 or byte > 57:
            return None
        var digit = Int128(byte - 48)
        value = value * 10 + (digit if positive else -digit)
        if value < minimum or value > maximum:
            return None
        position += 1
    return UInt64(bitcast[DType.uint128](value))


def _ascii_equal(text: String, expected: String) -> Bool:
    var a = text.as_bytes()
    var b = expected.as_bytes()
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        var byte = a[i]
        if byte >= 65 and byte <= 90:
            byte += 32
        if byte != b[i]:
            return False
    return True


def jsonb_to_bool(value: JsonbValue) raises -> Bool:
    if value.kind() == 4:
        return value.as_bool()
    if value.kind() == 1:
        var text = value.as_string()
        if _ascii_equal(text, "true") or _ascii_equal(text, "yes"):
            return True
        if _ascii_equal(text, "false") or _ascii_equal(text, "no"):
            return False
    raise Error("InvalidCast")


def jsonb_to_i64(value: JsonbValue) raises -> Int64:
    if value.kind() == 4:
        return Int64(value.as_bool())
    var integer = Optional[Int64]()
    if _numeric(value):
        integer = JsonbNumber.from_value(value).to_i64()
    elif value.kind() == 1:
        var text = value.as_string()
        var parsed = _parse_integer(text, True)
        if parsed:
            return bitcast[DType.int64](parsed.value())
        try:
            integer = JsonbNumber.floating(parse_fast_float(text.as_bytes())).to_i64()
        except:
            pass
    if integer:
        return integer.value()
    raise Error("InvalidCast")


def jsonb_to_u64(value: JsonbValue) raises -> UInt64:
    if value.kind() == 4:
        return UInt64(value.as_bool())
    var integer = Optional[UInt64]()
    if _numeric(value):
        integer = JsonbNumber.from_value(value).to_u64()
    elif value.kind() == 1:
        var text = value.as_string()
        var parsed = _parse_integer(text, False)
        if parsed:
            return parsed.value()
        try:
            integer = JsonbNumber.floating(parse_fast_float(text.as_bytes())).to_u64()
        except:
            pass
    if integer:
        return integer.value()
    raise Error("InvalidCast")


def jsonb_to_f64(value: JsonbValue) raises -> Float64:
    if value.kind() == 4:
        return Float64(value.as_bool())
    if _numeric(value):
        return JsonbNumber.from_value(value).as_f64()
    if value.kind() == 1:
        var text = value.as_string()
        try:
            return parse_fast_float(text.as_bytes())
        except:
            pass
    raise Error("InvalidCast")


def jsonb_to_str(value: JsonbValue) raises -> String:
    if value.kind() == 4:
        return "true" if value.as_bool() else "false"
    if value.kind() == 1:
        return value.as_string()
    if _numeric(value):
        return format_jsonb_number_display(JsonbNumber.from_value(value))
    raise Error("InvalidCast")
