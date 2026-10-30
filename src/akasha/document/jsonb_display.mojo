"""jsonb 0.5.6 Number/JsonPath Display (Datafuse Labs, Apache-2.0).

Decimal splitting follows number.rs, including its checked panic boundaries
and release i128 negation behavior. Wide division reuses the Number module's
ethnum 1.5.3 native division port (MIT, LLVM-derived).
Display is distinct from RawJsonb JSON serialization and is not a round-trip
path encoder: source strings and field names are deliberately unescaped.
"""
from std.memory import bitcast
from akasha.document.jsonb_number import JsonbNumber, _Wide, _wide_div128
from akasha.document.jsonb_path import JsonbPath, _validate_path
from akasha.document.zmij import format_zmij
from akasha.query.control import QueryControl


def _display_error() -> Error:
    return Error("JSONB Number Display source panic")


def _power(scale: Int) raises -> Int128:
    # Exact entries of source I128_POWERS_OF_10; reuse the ported ethnum power.
    if scale < 0 or scale > 38:
        raise _display_error()
    return Int128(_Wide(0, 10).pow(scale).low)


def _padded(width: Int, text: String) raises -> String:
    var count = width - text.byte_length()
    # Source usize subtraction and subsequent LEADING_ZEROS indexing panic
    # on underflow, or when the padding exceeds its 0..37 lookup table.
    if count < 0 or count > 37:
        raise _display_error()
    var result = String()
    for _ in range(count):
        result += "0"
    return result + text


def _trunc_divrem(value: Int128, divisor: Int128) -> Tuple[Int128, Int128]:
    # Primitive Rust signed division/remainder truncate rather than floor.
    var negative = value < 0
    var bits = bitcast[DType.uint128](value)
    var magnitude = UInt128(0) - bits if negative else bits
    var q = magnitude // UInt128(divisor)
    var r = magnitude % UInt128(divisor)
    if negative:
        q = UInt128(0) - q
        r = UInt128(0) - r
    return (bitcast[DType.int128](q), bitcast[DType.int128](r))


def _decimal128(var value: Int128, scale: Int) raises -> String:
    if scale == 0:
        return String(value)
    var sign = String()
    if value < 0:
        sign = "-"
        value = bitcast[DType.int128](UInt128(0) - bitcast[DType.uint128](value))
    var integer, fraction = _trunc_divrem(value, _power(scale))
    return sign + String(integer) + "." + _padded(scale, String(abs(fraction)))


def _decimal256(var value: _Wide, scale: Int) raises -> String:
    var sign = String()
    if value.negative():
        sign = "-"
        value = value.neg()
        if value.negative():
            raise _display_error()
    var quotient, remainder = _wide_div128(value, UInt128(_power(38)))
    # Source as_i128 truncates, including coefficients larger than 76 digits.
    var high = bitcast[DType.int128](quotient.low)
    var low = Int128(remainder)
    if scale == 0:
        if high > 0:
            return sign + String(high) + _padded(38, String(low))
        return sign + String(low)
    if scale >= 38:
        var high_scale = scale - 38
        var integer, fraction = _trunc_divrem(high, _power(high_scale))
        var result = sign + String(integer) + "."
        if high_scale > 0:
            result += _padded(high_scale, String(fraction))
        return result + _padded(38, String(low))
    var integer, fraction = _trunc_divrem(low, _power(scale))
    var result = sign
    if high > 0:
        result += String(high) + _padded(38 - scale, String(integer))
    else:
        result += String(integer)
    return result + "." + _padded(scale, String(fraction))


def format_jsonb_number_display(number: JsonbNumber, *, max_bytes: Int = 512) raises -> String:
    """Original Number Display, preserving exact Decimal scale/source quirks."""
    if max_bytes <= 0:
        raise Error("JSONB Display byte limit must be positive")
    var result: String
    if number.kind == 0:
        result = String(bitcast[DType.int64](UInt64(number.value.low)))
    elif number.kind == 1:
        result = String(UInt64(number.value.low))
    elif number.kind == 2:
        result = format_zmij(bitcast[DType.float64](UInt64(number.value.low)))
    elif number.kind == 3 or number.kind == 4:
        result = _decimal128(bitcast[DType.int128](number.value.low), Int(number.scale))
    elif number.kind == 5:
        result = _decimal256(number.value, Int(number.scale))
    else:
        raise Error("invalid JSONB Number kind")
    if result.byte_length() > max_bytes:
        raise Error("JSONB Display output byte resource limit exceeded")
    return result^


struct _PathDisplay(Movable):
    var output: String
    var max_bytes: Int
    var max_work: Int
    var work: Int
    var control: Optional[QueryControl]

    def __init__(out self, max_bytes: Int, max_work: Int, var control: Optional[QueryControl]) raises:
        if max_bytes <= 0 or max_work <= 0:
            raise Error("JSONB Display resource limits must be positive")
        self.output = String()
        self.max_bytes = max_bytes
        self.max_work = max_work
        self.work = 0
        self.control = control^

    def append(mut self, text: String) raises:
        if text.byte_length() > self.max_bytes - self.output.byte_length():
            raise Error("JSONB Display output byte resource limit exceeded")
        self.output += text

    def tick(mut self) raises:
        if self.work >= self.max_work:
            raise Error("JSONB Display work resource limit exceeded")
        self.work += 1
        if self.control:
            self.control.value().validate_candidate_count(self.work)
            self.control.value().checkpoint(0)

    def children(mut self, path: JsonbPath, indices: List[Int]) raises:
        for index in indices:
            self.node(path, index)

    def node(mut self, path: JsonbPath, index: Int) raises:
        self.tick()
        ref node = path.nodes[index]
        var kind = node.kind
        if kind <= 4:
            if kind == 0:
                self.append("$")
            elif kind == 1:
                self.append("@")
            elif kind == 2:
                self.append(".*")
            elif kind == 4:
                self.append("[*]")
            else:
                self.append(".**")
                if node.a >= 0:
                    self.append("{" + String(node.a))
                    if node.b >= 0:
                        self.append(" to " + (String("last") if node.b == 256 else String(node.b)))
                    self.append("}")
        elif kind >= 5 and kind <= 7:
            self.append(String(".") if kind == 5 else (String(":") if kind == 6 else String("[\"")))
            self.append(node.text)
            if kind == 7:
                self.append("\"]")
        elif kind == 8:
            self.append("[")
            for i in range(len(node.children)):
                if i > 0:
                    self.append(", ")
                self.node(path, node.children[i])
            self.append("]")
        elif kind == 9:
            self.append("?(")
            self.children(path, node.children)
            self.append(")")
        elif kind == 10 or kind == 11:
            self.children(path, node.children)
        elif kind == 12:
            if node.a == 0:
                self.append("null")
            elif node.a == 1:
                self.append(String("true") if node.bits != 0 else String("false"))
            elif node.a == 5:
                self.append("\"")
                self.append(node.text)
                self.append("\"")
            else:
                var number = JsonbNumber.integer(bitcast[DType.int64](node.bits))
                if node.a == 3:
                    number = JsonbNumber.unsigned(node.bits)
                elif node.a == 4:
                    number = JsonbNumber.floating(bitcast[DType.float64](node.bits))
                self.append(format_jsonb_number_display(number))
        elif kind == 13:
            var operators: List[String] = ["&&", "||", "==", "!=", "<", "<=", ">", ">=", "starts with", "+", "-", "*", "/", "%"]
            for i in range(2):
                if i == 1:
                    self.append(" " + operators[node.a] + " ")
                ref child = path.nodes[node.children[i]]
                var parentheses = child.kind == 13 and (child.a == 0 or child.a == 1)
                if parentheses:
                    self.append("(")
                self.node(path, node.children[i])
                if parentheses:
                    self.append(")")
        elif kind == 14:
            self.append(String("+") if node.a == 0 else String("-"))
            self.children(path, node.children)
        elif kind == 15:
            self.append("exists(")
            self.children(path, node.children)
            self.append(")")
        elif kind == 16:
            if node.a == 0:
                self.append(String(node.b))
            else:
                self.append("last")
                if node.b > 0:
                    self.append("+")
                if node.b != 0:
                    self.append(String(node.b))
        else:
            self.node(path, node.children[0])
            self.append(" to ")
            self.node(path, node.children[1])


def format_jsonb_path(path: JsonbPath, *, max_bytes: Int = 65_536,
                     max_work: Int = 1_000_000,
                     var control: Optional[QueryControl] = None) raises -> String:
    """Original Display of the existing parsed AST, with bounded owned output."""
    var writer = _PathDisplay(max_bytes, max_work, control^)
    writer.tick()
    _validate_path(path)
    writer.children(path, path.roots)
    var result = writer.output^
    writer.output = String()
    return result^
