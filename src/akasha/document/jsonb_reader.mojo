# Adapted from jsonb 0.5.6 parser.rs and util.rs.
# Copyright 2023 Datafuse Labs, Apache-2.0; see docs/upstream/licenses/.
# Both source profiles use databend without arbitrary_precision. This reader
# builds the existing owned binary type and enforces Akasha's resource bounds.
from akasha.document.jsonb import JsonbValue
from akasha.document.fast_float import parse_fast_float
from std.math import pow
from std.memory import bitcast


def _digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


def _hex(c: Int) -> Int:
    if _digit(c):
        return c - 48
    if c >= 65 and c <= 70:
        return c - 55
    if c >= 97 and c <= 102:
        return c - 87
    return -1


def _unicode(s: Span[UInt8, _], mut pos: Int) raises -> Tuple[Int, Int]:
    if len(s) - pos < 4:
        raise Error("incomplete JSONB Unicode escape")
    var start = pos
    if s[pos] == 123:
        if len(s) - pos < 6 or s[pos + 5] != 125:
            raise Error("incomplete JSONB braced Unicode escape")
        start += 1
        pos += 6
    else:
        pos += 4
    var value = 0
    for i in range(4):
        var digit = _hex(Int(s[start + i]))
        if digit < 0:
            raise Error("invalid JSONB hexadecimal escape")
        value = (value << 4) + digit
    return value, start


def _preserve_escape(mut output: List[UInt8], s: Span[UInt8, _], start: Int):
    output.append(92)
    output.append(117)
    for i in range(4):
        output.append(s[start + i])


def _append_codepoint(mut output: List[UInt8], cp: Int):
    # UTF-8 representation of Rust char::from_u32 for the validated scalar.
    if cp < 0x80:
        output.append(UInt8(cp))
    else:
        if cp < 0x800:
            output.append(UInt8((cp >> 6) | 0xC0))
        elif cp < 0x10000:
            output.append(UInt8((cp >> 12) | 0xE0))
            output.append(UInt8(((cp >> 6) & 0x3F) | 0x80))
        else:
            output.append(UInt8((cp >> 18) | 0xF0))
            output.append(UInt8(((cp >> 12) & 0x3F) | 0x80))
            output.append(UInt8(((cp >> 6) & 0x3F) | 0x80))
        output.append(UInt8((cp & 0x3F) | 0x80))


def _decode_string(s: Span[UInt8, _]) raises -> String:
    var output = List[UInt8]()
    var pos = 0
    while pos < len(s):
        var byte = s[pos]
        pos += 1
        if byte != 92:
            output.append(byte)
            continue
        if pos == len(s):
            raise Error("incomplete JSONB escape")
        byte = s[pos]
        pos += 1
        if byte == 92 or byte == 34 or byte == 47:
            output.append(byte)
        elif byte == 98:
            output.append(8)
        elif byte == 102:
            output.append(12)
        elif byte == 110:
            output.append(10)
        elif byte == 114:
            output.append(13)
        elif byte == 116:
            output.append(9)
        elif byte == 117:
            var first = _unicode(s, pos)
            var cp = first[0]
            if cp >= 0xDC00 and cp <= 0xDFFF:
                _preserve_escape(output, s, first[1])
                continue
            if cp >= 0xD800 and cp <= 0xDBFF:
                if len(s) - pos < 2 or s[pos] != 92 or s[pos + 1] != 117:
                    _preserve_escape(output, s, first[1])
                    continue
                pos += 2
                var second = _unicode(s, pos)
                if second[0] < 0xDC00 or second[0] > 0xDFFF:
                    _preserve_escape(output, s, first[1])
                    _preserve_escape(output, s, second[1])
                    continue
                cp = (((cp - 0xD800) << 10) | (second[0] - 0xDC00)) + 0x10000
            _append_codepoint(output, cp)
        else:
            raise Error("invalid JSONB escape")
    return String(from_utf8=Span(output))


struct _JsonbReader[origin: ImmOrigin](Movable):
    var bytes: Span[UInt8, Self.origin]
    var position: Int
    var standard: Bool
    var nodes: Int
    var content: Int

    def __init__(out self, bytes: Span[UInt8, Self.origin], standard: Bool) raises:
        if len(bytes) > JsonbValue.MAX_BYTES:
            raise Error("JSONB text exceeds byte limit")
        self.bytes = bytes
        self.position = 0
        self.standard = standard
        self.nodes = 0
        self.content = 0

    def peek(self) -> Int:
        return Int(self.bytes[self.position]) if self.position < len(self.bytes) else -1

    def next(self) raises -> Int:
        if self.position >= len(self.bytes):
            raise Error("unexpected end of JSONB text")
        return Int(self.bytes[self.position])

    def expect(mut self, expected: Int) raises:
        var byte = self.next()
        self.position += 1
        if byte != expected:
            raise Error("unexpected JSONB character")

    def skip_unused(mut self):
        while self.position < len(self.bytes):
            var c = self.peek()
            if c == 9 or c == 10 or c == 12 or c == 13 or c == 32:
                self.position += 1
                continue
            if c == 92 and self.position + 1 < len(self.bytes):
                var next = self.bytes[self.position + 1]
                if next == 110 or next == 114 or next == 116:
                    self.position += 2
                    continue
                if next == 120 and self.position + 3 < len(self.bytes) and self.bytes[self.position + 2] == 48 and self.bytes[self.position + 3] == 67:
                    self.position += 4
                    continue
            break

    def literal(mut self, text: String) raises:
        for expected in text.bytes():
            var byte = self.next()
            self.position += 1
            if byte != Int(expected) and (self.standard or byte != Int(expected) - 32):
                raise Error("invalid JSONB literal")

    def account_node(mut self) raises:
        if self.nodes == JsonbValue.MAX_NODES:
            raise Error("JSONB text node limit exceeded")
        self.nodes += 1

    def account_content(mut self, count: Int) raises:
        if count > JsonbValue.MAX_BYTES - self.content:
            raise Error("JSONB text decoded content limit exceeded")
        self.content += count

    def digits(mut self) -> Int:
        var start = self.position
        while _digit(self.peek()):
            self.position += 1
        return self.position - start

    def exponent(mut self) raises -> Bool:
        if self.peek() != 101 and self.peek() != 69:
            return False
        self.position += 1
        if self.peek() == 43 or self.peek() == 45:
            self.position += 1
        if self.digits() == 0:
            raise Error("invalid JSONB exponent")
        return True

    def standard_number(mut self) raises -> JsonbValue:
        var start = self.position
        var negative = self.peek() == 45
        if negative:
            self.position += 1
        var digits_start = self.position
        if self.peek() == 48:
            self.position += 1
            if _digit(self.peek()):
                raise Error("JSONB standard number has leading zeros")
        elif self.digits() == 0:
            raise Error("invalid JSONB standard number")
        var integer_end = self.position
        var fraction = self.peek() == 46
        if fraction:
            self.position += 1
            if self.digits() == 0:
                raise Error("invalid JSONB standard fraction")
        var exponent = self.exponent()
        if not fraction and not exponent:
            var value = UInt64(0)
            var fits = True
            for i in range(digits_start, integer_end):
                var digit = UInt64(self.bytes[i] - 48)
                if value > (UInt64.MAX - digit) // 10:
                    fits = False
                    break
                value = value * 10 + digit
            if fits:
                if not negative:
                    return JsonbValue.unsigned(value)
                if value <= (UInt64(1) << 63):
                    return JsonbValue.integer(bitcast[DType.int64](UInt64(0) - value))
        return JsonbValue.floating(parse_fast_float(self.bytes[start:self.position]))

    def hex_digits(mut self) raises -> Tuple[UInt128, Int]:
        var start = self.position
        var value = UInt128(0)
        while _hex(self.peek()) >= 0:
            var digit = UInt128(_hex(self.peek()))
            if value > (UInt128.MAX - digit) // 16:
                raise Error("JSONB hexadecimal number exceeds UInt128")
            value = value * 16 + digit
            self.position += 1
        if self.position == start:
            raise Error("missing JSONB hexadecimal digits")
        return value, self.position - start

    def extended_number(mut self) raises -> JsonbValue:
        var start = self.position
        var negative = self.peek() == 45
        if negative or self.peek() == 43:
            self.position += 1
        var zeros = 0
        while self.peek() == 48:
            zeros += 1
            self.position += 1
        var high = Int128(0)
        var scale = 0
        var precision = 0
        var fraction = False
        while precision < 76:
            var c = self.peek()
            if _digit(c):
                if precision < 38:
                    high = high * 10 + Int128(c - 48)
                self.position += 1
            elif c == 46:
                if fraction:
                    raise Error("duplicate JSONB decimal point")
                fraction = True
                self.position += 1
                continue
            else:
                break
            precision += 1
            if fraction:
                scale += 1
        if precision == 76:
            if not fraction:
                precision += self.digits()
                if self.peek() == 46:
                    fraction = True
                    self.position += 1
            if fraction:
                var count = self.digits()
                precision += count
                scale += count
        if zeros == 0 and precision == 0:
            if not fraction:
                var c = self.peek()
                if c == 105 or c == 73:
                    self.literal("infinity")
                    return JsonbValue.floating(bitcast[DType.float64](UInt64(0xfff0000000000000 if negative else 0x7ff0000000000000)))
                if c == 110 or c == 78:
                    self.literal("nan")
                    if negative:
                        raise Error("negative JSONB NaN is invalid")
                    return JsonbValue.floating(bitcast[DType.float64](UInt64(0x7ff8000000000000)))
            raise Error("invalid JSONB extended number")
        elif zeros == 1 and precision == 0 and not fraction and (self.peek() == 120 or self.peek() == 88):
            self.position += 1
            var integer = self.hex_digits()[0]
            if self.peek() == 46:
                self.position += 1
                var fractional = self.hex_digits()
                var divisor = pow(Float64(16), fractional[1])
                var value = Float64(integer) + Float64(fractional[0]) / divisor
                return JsonbValue.floating(-value if negative else value)
            if negative:
                if integer <= (UInt128(1) << 63):
                    return JsonbValue.integer(bitcast[DType.int64](UInt64(0) - UInt64(integer)))
                return JsonbValue.floating(-Float64(integer))
            if integer <= UInt128(UInt64.MAX):
                return JsonbValue.unsigned(UInt64(integer))
            return JsonbValue.floating(Float64(integer))
        var exponent = self.exponent()
        if not exponent and precision <= 38:
            var value = -high if negative else high
            if scale == 0:
                if value >= 0 and value <= Int128(UInt64.MAX):
                    return JsonbValue.unsigned(UInt64(value))
                if value >= Int128(Int64.MIN) and value <= Int128(Int64.MAX):
                    return JsonbValue.integer(Int64(value))
        return JsonbValue.floating(parse_fast_float(self.bytes[start:self.position]))

    def quoted_string(mut self, quote: Int) raises -> String:
        var start = self.position
        var escapes = 0
        while True:
            var byte = self.next()
            self.position += 1
            if byte == 92:
                escapes += 1
                var escaped = self.next()
                self.position += 1
                if escaped == 117:
                    var next = self.next()
                    self.position += 6 if next == 123 else 4
            elif byte == quote:
                break
        var data = self.bytes[start:self.position - 1]
        var result = _decode_string(data) if escapes != 0 else String(from_utf8=data)
        self.account_content(result.byte_length())
        return result^

    def key(mut self) raises -> String:
        var byte = self.next()
        if self.standard:
            self.expect(34)
            return self.quoted_string(34)
        if byte == 34 or byte == 39:
            self.position += 1
            return self.quoted_string(byte)
        var start = self.position
        if _digit(byte):
            raise Error("JSONB unquoted key cannot start with a digit")
        while True:
            byte = self.next()
            if _digit(byte) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) or byte == 95 or byte == 36:
                self.position += 1
            elif byte >= 128:
                if byte >= 240:
                    self.position += 4
                elif byte >= 224:
                    self.position += 3
                elif byte >= 192:
                    self.position += 2
                else:
                    raise Error("invalid JSONB UTF-8 key")
            else:
                break
        if start == self.position:
            raise Error("invalid JSONB unquoted key")
        var result = String(from_utf8=self.bytes[start:self.position])
        self.account_content(result.byte_length())
        return result^

    def container(mut self, object: Bool, depth: Int) raises -> JsonbValue:
        if depth >= JsonbValue.MAX_DEPTH:
            raise Error("JSONB text nesting depth exceeded")
        self.position += 1
        var first = True
        var values = List[JsonbValue]()
        var keys = List[String]()
        while True:
            self.skip_unused()
            var c = self.next()
            if c == (125 if object else 93):
                self.position += 1
                break
            if not first:
                self.expect(44)
            first = False
            self.skip_unused()
            if object:
                keys.append(self.key())
                self.skip_unused()
                self.expect(58)
                values.append(self.value(depth + 1))
            elif not self.standard and (self.peek() == 44 or self.peek() == 93):
                self.account_node()
                values.append(JsonbValue.null())
            else:
                values.append(self.value(depth + 1))
        # Existing source-backed builder sorts keys and rejects duplicates.
        return JsonbValue.object(keys, values) if object else JsonbValue.array(values)

    def value(mut self, depth: Int) raises -> JsonbValue:
        self.account_node()
        self.skip_unused()
        var c = self.peek()
        if not self.standard and c == -1:
            return JsonbValue.null()
        if c == 110 or (not self.standard and c == 78):
            var start = self.position
            try:
                self.literal("null")
                return JsonbValue.null()
            except err:
                if self.standard:
                    raise err
                self.position = start
                self.literal("nan")
                return JsonbValue.floating(bitcast[DType.float64](UInt64(0x7ff8000000000000)))
        if c == 116 or (not self.standard and c == 84):
            self.literal("true")
            return JsonbValue.boolean(True)
        if c == 102 or (not self.standard and c == 70):
            self.literal("false")
            return JsonbValue.boolean(False)
        if not self.standard and (c == 105 or c == 73):
            self.literal("infinity")
            return JsonbValue.floating(bitcast[DType.float64](UInt64(0x7ff0000000000000)))
        if _digit(c) or c == 45 or (not self.standard and (c == 43 or c == 46)):
            return self.standard_number() if self.standard else self.extended_number()
        if c == 34 or (not self.standard and c == 39):
            self.position += 1
            return JsonbValue.string(self.quoted_string(c))
        if c == 91 or c == 123:
            return self.container(c == 123, depth)
        raise Error("expected JSONB value")


def parse_jsonb_bytes[origin: ImmOrigin](bytes: Span[UInt8, origin], *, standard: Bool = False) raises -> JsonbValue:
    """Parse original jsonb standard/extended text into an owned bounded value."""
    var reader = _JsonbReader(bytes, standard)
    var value = reader.value(0)
    reader.skip_unused()
    if reader.position < len(bytes):
        raise Error("unexpected trailing JSONB characters")
    return value^


def parse_jsonb(text: String, *, standard: Bool = False) raises -> JsonbValue:
    return parse_jsonb_bytes(text.as_bytes(), standard=standard)
