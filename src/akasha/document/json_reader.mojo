"""Bounded owned-value reader ported from serde_json 1.0.151 (MIT/Apache-2.0).

Sources: de.rs parse_integer/number/decimal/exponent, SeqAccess/MapAccess;
read.rs parse_escape/parse_unicode_escape/push_wtf8_codepoint. This explicitly
implements the default numeric profile without float_roundtrip. The source
oracle fixes that feature set; it is not a claim of Lance/jsonb equivalence.
"""
from akasha.document.value import PayloadValue
from akasha.document.json_number_tables import json_powers_of_ten
from std.math import isfinite


def _digit(byte: Int) -> Bool:
    return byte >= 48 and byte <= 57


def _float_parts(positive: Bool, significand: UInt64, var exponent: Int) raises -> Float64:
    var value = Float64(significand)
    var powers = json_powers_of_ten()
    while True:
        if exponent >= -308 and exponent <= 308:
            if exponent >= 0:
                value *= powers[exponent]
                if not isfinite(value):
                    raise Error("JSON number out of range")
            else:
                value /= powers[-exponent]
            break
        if value == 0.0:
            break
        if exponent >= 0:
            raise Error("JSON number out of range")
        value /= 1e308
        exponent += 308
    return value if positive else -value


struct _JsonReader[origin: ImmOrigin](Movable):
    var bytes: Span[UInt8, Self.origin]
    var position: Int
    var nodes: Int
    var content: Int

    def __init__(out self, bytes: Span[UInt8, Self.origin]) raises:
        if len(bytes) > PayloadValue.MAX_BYTES:
            raise Error("JSON source byte resource limit exceeded")
        self.bytes = bytes
        self.position = 0
        self.nodes = 0
        self.content = 0

    def peek(self) -> Int:
        return Int(self.bytes[self.position]) if self.position < len(self.bytes) else -1

    def take(mut self) raises -> Int:
        if self.position == len(self.bytes):
            raise Error("unexpected end of JSON input")
        var result = Int(self.bytes[self.position])
        self.position += 1
        return result

    def space(mut self):
        while self.position < len(self.bytes):
            var byte = self.peek()
            if byte != 32 and byte != 9 and byte != 10 and byte != 13:
                break
            self.position += 1

    def expect(mut self, byte: Int) raises:
        if self.take() != byte:
            raise Error("unexpected JSON token")

    def account(mut self, count: Int) raises:
        if count > PayloadValue.MAX_BYTES - self.content:
            raise Error("JSON decoded content resource limit exceeded")
        self.content += count

    def hex4(mut self) raises -> Int:
        var value = 0
        for _ in range(4):
            var byte = self.take()
            var digit: Int
            if _digit(byte):
                digit = byte - 48
            elif byte >= 65 and byte <= 70:
                digit = byte - 55
            elif byte >= 97 and byte <= 102:
                digit = byte - 87
            else:
                raise Error("invalid JSON Unicode escape")
            value = value * 16 + digit
        return value

    def string(mut self) raises -> String:
        self.expect(34)
        var output = List[UInt8]()
        while True:
            var byte = self.take()
            if byte == 34:
                self.account(len(output))
                return String(from_utf8=Span(output))
            if byte < 32:
                raise Error("unescaped control character in JSON string")
            if byte != 92:
                output.append(UInt8(byte))
                continue
            byte = self.take()
            if byte == 34 or byte == 92 or byte == 47:
                output.append(UInt8(byte))
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
                var cp = self.hex4()
                if cp >= 0xDC00 and cp <= 0xDFFF:
                    raise Error("unpaired JSON trailing surrogate")
                if cp >= 0xD800 and cp <= 0xDBFF:
                    self.expect(92)
                    self.expect(117)
                    var low = self.hex4()
                    if low < 0xDC00 or low > 0xDFFF:
                        raise Error("unpaired JSON leading surrogate")
                    cp = (((cp - 0xD800) << 10) | (low - 0xDC00)) + 0x10000
                # Source read.rs push_wtf8_codepoint; validate=true above.
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
            else:
                raise Error("invalid JSON escape")

    def exponent(mut self, positive: Bool, significand: UInt64, starting: Int) raises -> Float64:
        self.position += 1
        var positive_exp = True
        if self.peek() == 43 or self.peek() == 45:
            positive_exp = self.peek() == 43
            self.position += 1
        var byte = self.take()
        if not _digit(byte):
            raise Error("invalid JSON exponent")
        var exponent = byte - 48
        while _digit(self.peek()):
            var digit = self.take() - 48
            if exponent > (Int(Int32.MAX) - digit) // 10:
                if positive_exp and significand != 0:
                    raise Error("JSON number out of range")
                while _digit(self.peek()):
                    self.position += 1
                return 0.0 if positive else -0.0
            exponent = exponent * 10 + digit
        var combined = starting + exponent if positive_exp else starting - exponent
        combined = max(Int(Int32.MIN), min(Int(Int32.MAX), combined))
        return _float_parts(positive, significand, combined)

    def decimal(mut self, positive: Bool, var significand: UInt64, before: Int) raises -> Float64:
        self.position += 1
        var after = 0
        while _digit(self.peek()):
            var digit = UInt64(self.peek() - 48)
            if significand > (UInt64.MAX - digit) // 10:
                while _digit(self.peek()):
                    self.position += 1
                if self.peek() == 101 or self.peek() == 69:
                    return self.exponent(positive, significand, before + after)
                return _float_parts(positive, significand, before + after)
            self.position += 1
            significand = significand * 10 + digit
            after -= 1
        if after == 0:
            raise Error("JSON decimal requires a digit")
        if self.peek() == 101 or self.peek() == 69:
            return self.exponent(positive, significand, before + after)
        return _float_parts(positive, significand, before + after)

    def long_integer(mut self, positive: Bool, significand: UInt64) raises -> Float64:
        var exponent = 0
        while _digit(self.peek()):
            self.position += 1
            exponent += 1
        if self.peek() == 46:
            return self.decimal(positive, significand, exponent)
        if self.peek() == 101 or self.peek() == 69:
            return self.exponent(positive, significand, exponent)
        return _float_parts(positive, significand, exponent)

    def number(mut self) raises -> PayloadValue:
        self.account(8)
        var positive = self.peek() != 45
        if not positive:
            self.position += 1
        var first = self.take()
        if not _digit(first):
            raise Error("invalid JSON number")
        var significand = UInt64(first - 48)
        if first == 48:
            if _digit(self.peek()):
                raise Error("leading zero in JSON number")
        else:
            while _digit(self.peek()):
                var digit = UInt64(self.peek() - 48)
                if significand > (UInt64.MAX - digit) // 10:
                    return PayloadValue.floating(self.long_integer(positive, significand))
                self.position += 1
                significand = significand * 10 + digit
        if self.peek() == 46:
            return PayloadValue.floating(self.decimal(positive, significand, 0))
        if self.peek() == 101 or self.peek() == 69:
            return PayloadValue.floating(self.exponent(positive, significand, 0))
        if positive:
            if significand <= UInt64(Int64.MAX):
                return PayloadValue.integer(Int64(significand))
            return PayloadValue.unsigned(significand)
        if significand == UInt64(1) << 63:
            return PayloadValue.integer(Int64.MIN)
        if significand == 0 or significand > UInt64(Int64.MAX):
            return PayloadValue.floating(-Float64(significand))
        return PayloadValue.integer(-Int64(significand))

    def value(mut self, depth: Int) raises -> PayloadValue:
        self.space()
        if self.nodes == PayloadValue.MAX_NODES:
            raise Error("JSON parsed node resource limit exceeded")
        self.nodes += 1
        var byte = self.peek()
        if byte == 34:
            return PayloadValue.string(self.string())
        if byte == 45 or _digit(byte):
            return self.number()
        if byte == 110:
            var literal = String("null")
            for expected in literal.bytes():
                self.expect(Int(expected))
            return PayloadValue.null()
        if byte == 116 or byte == 102:
            var literal = "true" if byte == 116 else "false"
            for expected in literal.bytes():
                self.expect(Int(expected))
            self.account(8)
            return PayloadValue.boolean(byte == 116)
        if byte != 91 and byte != 123:
            raise Error("expected JSON value")
        if depth >= PayloadValue.MAX_DEPTH:
            raise Error("JSON nesting depth resource limit exceeded")
        var object = byte == 123
        var end = 125 if object else 93
        self.position += 1
        self.space()
        var keys = List[String]()
        var values = List[PayloadValue]()
        if self.peek() != end:
            while True:
                if object:
                    keys.append(self.string())
                    self.space()
                    self.expect(58)
                values.append(self.value(depth + 1))
                self.space()
                if self.peek() == end:
                    break
                self.expect(44)
                self.space()
                if self.peek() == end:
                    raise Error("trailing comma in JSON container")
        self.expect(end)
        if object:
            return PayloadValue.object(keys^, values^)
        return PayloadValue.array(values^)


def parse_json_bytes[origin: ImmOrigin](bytes: Span[UInt8, origin]) raises -> PayloadValue:
    """Parse one owned value; source bytes are borrowed only for this call.

    Akasha's 64-level, 65,536 parsed-node and 16 MiB source/content limits
    apply, including duplicate members discarded by last-write-wins semantics.
    """
    var reader = _JsonReader(bytes)
    var result = reader.value(0)
    reader.space()
    if reader.position != len(bytes):
        raise Error("trailing characters after JSON value")
    return result^


def parse_json(value: String) raises -> PayloadValue:
    return parse_json_bytes(value.as_bytes())
