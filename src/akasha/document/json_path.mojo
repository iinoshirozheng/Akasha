"""Qdrant JSON-path grammar and structural operations (Apache-2.0).

Source: segment/src/json_path/{parse,mod}.rs at
74f3e85b9473c62560006c043e13737ce6b48412. Native bounded cursor storage
replaces nom combinators; Unicode classification follows Rust 1.97.1.
"""
from akasha.document.unicode_alphanumeric import is_alphanumeric
from std.collections.string import Codepoint


@fieldwise_init
struct JsonPathItem(Copyable, Movable):
    # Key = 1, index = 2, wildcard = 3, in upstream enum order.
    var kind: UInt8
    var key: String
    var index: UInt64

    def same(self, other: JsonPathItem) -> Bool:
        return self.kind == other.kind and (
            self.key == other.key if self.kind == 1 else
            self.index == other.index if self.kind == 2 else True)


def key_needs_quoting(key: String) -> Bool:
    if key == "":
        return True
    for cp in key.codepoints():
        if not _raw_character(Int(cp)):
            return True
    return False


def _raw_character(cp: Int) -> Bool:
    return cp == 95 or cp == 45 or is_alphanumeric(cp)


def _read_key(codepoints: List[Codepoint], mut cursor: Int) raises -> String:
    if cursor == len(codepoints):
        raise Error("invalid JSON path: missing key")
    var result = String()
    if Int(codepoints[cursor]) == 34:
        cursor += 1
        while cursor < len(codepoints):
            var cp = codepoints[cursor]
            cursor += 1
            if Int(cp) == 34:
                return result^
            if Int(cp) == 92:
                raise Error("Qdrant quoted JSON path keys do not support backslash escapes")
            result += String(cp)
        raise Error("invalid JSON path: unclosed quoted key")
    while cursor < len(codepoints) and _raw_character(Int(codepoints[cursor])):
        result += String(codepoints[cursor])
        cursor += 1
    if result == "":
        raise Error("invalid JSON path key")
    return result^


@fieldwise_init
struct JsonPath(Copyable, Movable):
    var first_key: String
    var rest: List[JsonPathItem]

    comptime MAX_BYTES = 65_536
    comptime MAX_PARTS = 1024

    @staticmethod
    def parse(value: String) raises -> JsonPath:
        if value.byte_length() > Self.MAX_BYTES:
            raise Error("JSON path byte resource limit exceeded")
        var codepoints = List[Codepoint]()
        for cp in value.codepoints():
            codepoints.append(cp)
        var cursor = 0
        var first = _read_key(codepoints, cursor)
        var rest = List[JsonPathItem]()
        while cursor < len(codepoints):
            if len(rest) >= Self.MAX_PARTS - 1:
                raise Error("JSON path part resource limit exceeded")
            var cp = Int(codepoints[cursor])
            cursor += 1
            if cp == 46:
                rest.append(JsonPathItem(1, _read_key(codepoints, cursor), 0))
            elif cp == 91:
                if cursor < len(codepoints) and Int(codepoints[cursor]) == 93:
                    cursor += 1
                    rest.append(JsonPathItem(3, "", 0))
                    continue
                var index = UInt64(0)
                var digits = 0
                while cursor < len(codepoints):
                    var digit = Int(codepoints[cursor]) - 48
                    if digit < 0 or digit > 9:
                        break
                    if index > (UInt64.MAX - UInt64(digit)) // 10:
                        raise Error("JSON path index exceeds UInt64")
                    index = index * 10 + UInt64(digit)
                    cursor += 1
                    digits += 1
                if digits == 0 or cursor == len(codepoints) or Int(codepoints[cursor]) != 93:
                    raise Error("invalid JSON path array index")
                cursor += 1
                rest.append(JsonPathItem(2, "", index))
            else:
                raise Error("invalid JSON path suffix")
        return JsonPath(first^, rest^)

    def display(self) -> String:
        var result = _display_key(self.first_key)
        for i in range(len(self.rest)):
            ref item = self.rest[i]
            if item.kind == 1:
                result += "." + _display_key(item.key)
            elif item.kind == 2:
                result += "[" + String(item.index) + "]"
            else:
                result += "[]"
        return result^

    def has_wildcard_suffix(self) -> Bool:
        return len(self.rest) > 0 and self.rest[len(self.rest) - 1].kind == 3

    def strip_wildcard_suffix(self) -> JsonPath:
        var result = self.copy()
        if self.has_wildcard_suffix():
            _ = result.rest.pop()
        return result^

    def array_key(self) raises -> JsonPath:
        var result = self.copy()
        if not self.has_wildcard_suffix():
            if len(result.rest) >= Self.MAX_PARTS - 1:
                raise Error("JSON path part resource limit exceeded")
            if self.display().byte_length() + 2 > Self.MAX_BYTES:
                raise Error("JSON path byte resource limit exceeded")
            result.rest.append(JsonPathItem(3, "", 0))
        return result^

    def extend(self, other: JsonPath) raises -> JsonPath:
        if len(self.rest) + len(other.rest) + 2 > Self.MAX_PARTS:
            raise Error("JSON path part resource limit exceeded")
        if self.display().byte_length() + other.display().byte_length() + 1 > Self.MAX_BYTES:
            raise Error("JSON path byte resource limit exceeded")
        var result = self.copy()
        result.rest.append(JsonPathItem(1, other.first_key.copy(), 0))
        for i in range(len(other.rest)):
            result.rest.append(other.rest[i].copy())
        return result^

    def strip_prefix(self, prefix: JsonPath) -> Optional[JsonPath]:
        if self.first_key != prefix.first_key or len(prefix.rest) >= len(self.rest):
            return None
        for i in range(len(prefix.rest)):
            if not self.rest[i].same(prefix.rest[i]):
                return None
        var next = len(prefix.rest)
        if self.rest[next].kind != 1:
            return None
        var tail = List[JsonPathItem]()
        for i in range(next + 1, len(self.rest)):
            tail.append(self.rest[i].copy())
        return Optional(JsonPath(self.rest[next].key.copy(), tail^))

    def check_include_pattern(self, pattern: JsonPath) -> Bool:
        if self.first_key != pattern.first_key:
            return False
        for i in range(min(len(self.rest), len(pattern.rest))):
            if not self.rest[i].same(pattern.rest[i]):
                return False
        return True

    def check_exclude_pattern(self, pattern: JsonPath) -> Bool:
        # Preserve the source implementation's direction, even though its
        # prose comment describes the reverse prefix relationship.
        return len(pattern.rest) >= len(self.rest) and self.check_include_pattern(pattern)

    def compatible(self, other: JsonPath) -> Bool:
        if self.first_key != other.first_key:
            return False
        for i in range(min(len(self.rest), len(other.rest))):
            ref a = self.rest[i]
            ref b = other.rest[i]
            if a.kind >= 2 and b.kind >= 2 and (a.kind == 3 or b.kind == 3):
                continue
            if not a.same(b):
                return False
        return True


def _display_key(key: String) -> String:
    return "\"" + key + "\"" if key_needs_quoting(key) else key.copy()


@fieldwise_init
struct FormulaVariable(Copyable, Movable):
    var score_index: Optional[UInt64]
    var path: Optional[JsonPath]

    @staticmethod
    def parse(value: String) raises -> FormulaVariable:
        # Qdrant VariableId::from_str parses reserved names through the same
        # JSON-path grammar, so $"score" and leading-zero indexes are legal.
        if value.startswith("$"):
            var path = JsonPath.parse(String(value.removeprefix("$")))
            if path.first_key != "score":
                raise Error("invalid reserved formula variable")
            if len(path.rest) == 0:
                return FormulaVariable(Optional(UInt64(0)), None)
            if len(path.rest) == 1 and path.rest[0].kind == 2:
                return FormulaVariable(Optional(path.rest[0].index), None)
            raise Error("invalid reserved formula score index")
        return FormulaVariable(None, Optional(JsonPath.parse(value)))

    def same(self, other: FormulaVariable) -> Bool:
        if self.score_index:
            return Bool(other.score_index) and self.score_index.value() == other.score_index.value()
        if other.score_index:
            return False
        ref a = self.path.value()
        ref b = other.path.value()
        return len(a.rest) == len(b.rest) and a.check_include_pattern(b)
