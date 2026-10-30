"""RawJsonb serde text writer port: jsonb 0.5.6 and serde_json 1.0.151.

Walks the validated owned binary body in wire order. Compact/pretty punctuation
and UTF-8 string escaping follow serde_json's formatters; number and extension
conversions follow the source profiles. No JSON stringify/repr FFI is used.
"""
from akasha.query.control import QueryControl
from akasha.document.jsonb import JsonbValue, _read_be
from akasha.document.jsonb_formatting import format_jsonb_number, format_jsonb_extension


struct _JsonbWriter(Movable):
    var bytes: List[UInt8]
    var pretty: Bool
    var max_bytes: Int
    var control: Optional[QueryControl]

    def __init__(out self, pretty: Bool, max_bytes: Int, var control: Optional[QueryControl]) raises:
        if max_bytes < 0:
            raise Error("JSONB output byte limit cannot be negative")
        self.bytes = List[UInt8]()
        self.pretty = pretty
        self.max_bytes = max_bytes
        self.control = control^

    def put(mut self, byte: UInt8) raises:
        if len(self.bytes) >= self.max_bytes:
            raise Error("JSONB output byte resource limit exceeded")
        if self.control:
            self.control.value().checkpoint(len(self.bytes))
        self.bytes.append(byte)

    def text(mut self, text: String) raises:
        for byte in text.as_bytes():
            self.put(byte)

    def indent(mut self, depth: Int) raises:
        self.put(10)
        for _ in range(depth * 2):
            self.put(32)

    def quoted(mut self, bytes: Span[UInt8, _]) raises:
        self.put(34)
        var hex = "0123456789abcdef"
        for byte in bytes:
            var escape = UInt8(0)
            if byte == 34 or byte == 92:
                escape = byte
            elif byte == 8:
                escape = 98
            elif byte == 9:
                escape = 116
            elif byte == 10:
                escape = 110
            elif byte == 12:
                escape = 102
            elif byte == 13:
                escape = 114
            if escape != 0:
                self.put(92)
                self.put(escape)
            elif byte < 32:
                self.text("\\u00")
                self.put(hex.as_bytes()[Int(byte >> 4)])
                self.put(hex.as_bytes()[Int(byte & 15)])
            else:
                self.put(byte)
        self.put(34)

    def atom(mut self, tag: UInt32, body: Span[UInt8, _], depth: Int) raises:
        if tag == 0:
            self.text("null")
        elif tag == 0x10000000:
            self.quoted(body)
        elif tag == 0x20000000:
            self.text(format_jsonb_number(body))
        elif tag == 0x30000000:
            self.text("false")
        elif tag == 0x40000000:
            self.text("true")
        elif tag == 0x50000000:
            self.container(body, depth)
        else:
            # Binary's uppercase hexadecimal expansion is produced before
            # quoting; bound that intermediate allocation as well.
            if body[0] == 0 and 2 * (len(body) - 1) + 2 > self.max_bytes - len(self.bytes):
                raise Error("JSONB output byte resource limit exceeded")
            var text = format_jsonb_extension(body, self.control)
            self.quoted(text.as_bytes())

    def container(mut self, body: Span[UInt8, _], depth: Int) raises:
        var header = UInt32(_read_be(body, 0, 4))
        var kind = header & UInt32(0xE0000000)
        var count = Int(header & UInt32(0x1FFFFFFF))
        if kind == 0x20000000:
            var entry = UInt32(_read_be(body, 4, 4))
            self.atom(entry & UInt32(0x70000000), body[8:], depth)
            return
        var object = kind == 0x40000000
        var key_position = 4 + count * (8 if object else 4)
        var position = key_position
        var entry_position = 4
        if object:
            for i in range(count):
                position += Int(UInt32(_read_be(body, 4 + i * 4, 4)) & UInt32(0x0FFFFFFF))
            entry_position += count * 4
        self.put(UInt8(123) if object else UInt8(91))
        for i in range(count):
            if i != 0:
                self.put(44)
            if self.pretty:
                self.indent(depth + 1)
            if object:
                var key_length = Int(UInt32(_read_be(body, 4 + i * 4, 4)) & UInt32(0x0FFFFFFF))
                self.quoted(body[key_position:key_position + key_length])
                key_position += key_length
                self.put(58)
                if self.pretty:
                    self.put(32)
            var entry = UInt32(_read_be(body, entry_position + i * 4, 4))
            var size = Int(entry & UInt32(0x0FFFFFFF))
            self.atom(entry & UInt32(0x70000000), body[position:position + size], depth + 1)
            position += size
        if self.pretty and count != 0:
            self.indent(depth)
        self.put(UInt8(125) if object else UInt8(93))


def format_jsonb(
    value: JsonbValue, *, pretty: Bool = False, max_bytes: Int = Int.MAX,
    var control: Optional[QueryControl] = None,
) raises -> String:
    """Serialize a checked JSONB value with the pinned RawJsonb text contract.

    Existing byte/node/depth bounds on the owned value bound output growth;
    escaping/indentation can produce more bytes than the binary body. Invalid
    source calendar ranges raise instead of reproducing Rust's unwrap panic.
    """
    var writer = _JsonbWriter(pretty, max_bytes, control^)
    if writer.control:
        writer.control.value().checkpoint(0)
    writer.container(Span(value._data), 0)
    return String(from_utf8=Span(writer.bytes))
