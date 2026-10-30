"""Lance JSON consumer functions (Lance Authors, Apache-2.0).

Ported from lance-arrow/json.rs and lance-datafusion/udf/json.rs. Exact key
access follows jsonb 0.5.6 path.rs/util.rs (Datafuse Labs, Apache-2.0).
The existing source selector, scalar casts and writer remain authoritative.
"""
from akasha.document.jsonb import JsonbValue, _read_be
from akasha.document.jsonb_path import JsonbPath
from akasha.document.jsonb_selector import JsonbSelector, _Selection
from akasha.document.jsonb_number import JsonbNumber
from akasha.document.jsonb_cast import _parse_integer, jsonb_to_str, jsonb_to_i64, jsonb_to_f64, jsonb_to_bool
from akasha.document.jsonb_writer import format_jsonb
from akasha.query.control import QueryControl


def _parse(path: String) raises -> JsonbPath:
    try:
        return JsonbPath.parse(path)
    except error:
        if String(error).__contains__("resource limit"):
            raise error
        # The native parser exposes diagnostics; the source consumers expose
        # jsonb::Error::InvalidJsonPath at this boundary.
        raise Error("InvalidJsonPath")


def _entry(value: JsonbValue, entry: Int, position: Int) raises -> JsonbValue:
    var tag = UInt32(_read_be(Span(value._data), entry, 4))
    var size = Int(tag & UInt32(0x0FFFFFFF))
    var data = Span(value._data)[position:position + size]
    if tag & UInt32(0x70000000) == 0x50000000:
        return JsonbValue(data)
    return JsonbValue._scalar(tag & UInt32(0x70000000), data)


def jsonb_get_by_index(value: JsonbValue, index: UInt64) raises -> Optional[JsonbValue]:
    """Source ArrayIterator::nth/from_item; nonarrays and missing return None."""
    if value.kind() != 6:
        return None
    var count = value._count()
    if index >= UInt64(count):
        return None
    var position = 4 + 4 * count
    for i in range(Int(index)):
        position += Int(UInt32(_read_be(Span(value._data), 4 + 4 * i, 4)) & UInt32(0x0FFFFFFF))
    return _entry(value, 4 + 4 * Int(index), position)


def jsonb_get_by_name(value: JsonbValue, name: String) raises -> Optional[JsonbValue]:
    """Source get_object_value_by_key_name with exact byte equality."""
    if value.kind() != 7:
        return None
    var count = value._count()
    var index = 0
    var entry = 4
    var position = 4 + 8 * count
    var matched = False
    while index < count:
        var size = Int(UInt32(_read_be(Span(value._data), entry, 4)) & UInt32(0x0FFFFFFF))
        index += 1
        entry += 4
        position += size
        if size == name.byte_length():
            var bytes = Span(value._data)[position - size:position]
            if bytes == name.as_bytes():
                matched = True
                break
    if not matched:
        return None
    var value_index = index - 1
    while index < count + value_index:
        position += Int(UInt32(_read_be(Span(value._data), entry, 4)) & UInt32(0x0FFFFFFF))
        entry += 4
        index += 1
    return _entry(value, entry, position)


def lance_json_type(value: JsonbValue) raises -> UInt8:
    """Lance JsonbType: preserve storage classification independently of bytes."""
    var kind = value.kind()
    if kind == 5:
        return 0
    if kind == 4:
        return 1
    if kind == 2 or kind == 3 or kind == 8 or kind == 9:
        var number = JsonbNumber.from_value(value)
        return 2 if number.kind != 2 and Bool(number.as_i64()) else 3
    if kind == 6:
        return 5
    if kind == 7:
        return 6
    # Source extension values receive String without converting their bytes.
    return 4


struct LanceJson(Copyable, Movable):
    """Owned value operations used by Lance's JSON UDFs, with native limits."""
    var selector: JsonbSelector

    def __init__(out self, var value: JsonbValue, *, max_work: Int = 1_000_000,
                 max_results: Int = 65_536, max_bytes: Int = 64 * 1024 * 1024,
                 var control: Optional[QueryControl] = None) raises:
        self.selector = JsonbSelector(value^, max_work=max_work, max_results=max_results,
                                      max_bytes=max_bytes, control=control^)

    def _budget(self) raises -> _Selection:
        return _Selection(self.selector.max_work, self.selector.max_results,
                          self.selector.max_bytes, self.selector.control.copy())

    def _text(self, value: JsonbValue) raises -> String:
        return format_jsonb(value, max_bytes=self.selector.max_bytes, control=self.selector.control.copy())

    def _path(self, path: String) raises -> JsonbPath:
        try:
            return _parse(path)
        except error:
            raise Error("Invalid JSONPath '" + path + "': " + String(error))

    def json_path(self, path: String) raises -> Optional[String]:
        # Arrow helper executes select_values fully, then renders its first.
        try:
            var parsed = _parse(path)
            var values = self.selector.select_values(parsed)
            if len(values) == 0:
                return None
            return self._text(values[0])
        except error:
            raise Error("Invalid argument error: Failed to extract JSONPath: " + String(error))

    def _selected(self, path: String) raises -> Optional[JsonbValue]:
        var parsed = self._path(path)
        try:
            return self.selector.select_value(parsed)
        except error:
            raise Error("Failed to select value from path '" + path + "': " + String(error))

    def extract(self, path: String) raises -> Optional[String]:
        var value = self._selected(path)
        if not value:
            return None
        return self._text(value.value())

    def extract_with_type(self, path: String) raises -> Optional[Tuple[JsonbValue, UInt8]]:
        var value = self._selected(path)
        if not value:
            return None
        var tag = lance_json_type(value.value())
        return (value.take(), tag)

    def exists(self, path: String) raises -> Bool:
        var parsed = self._path(path)
        try:
            return self.selector.exists(parsed)
        except error:
            raise Error("Failed to check existence of path '" + path + "': " + String(error))

    def get(self, key: String) raises -> Optional[JsonbValue]:
        var budget = self._budget()
        var kind = self.selector.root.kind()
        if kind != 6 and kind != 7:
            return None
        var count = self.selector.root._count()
        budget.tick(count)
        var value = Optional[JsonbValue]()
        if kind == 7:
            value = jsonb_get_by_name(self.selector.root, key)
        else:
            # Rust usize parsing, on the project's supported 64-bit platforms.
            var index = _parse_integer(key, False)
            if index:
                value = jsonb_get_by_index(self.selector.root, index.value())
        if value:
            budget.charge(len(value.value()._data))
        return value^

    def get_string(self, key: String) raises -> Optional[String]:
        var value = self.get(key)
        if not value or value.value().kind() == 5:
            return None
        var text: String
        try:
            text = jsonb_to_str(value.value())
        except error:
            raise Error("Failed to convert to string: " + String(error))
        if text.byte_length() > self.selector.max_bytes:
            raise Error("JSONB string byte resource limit exceeded")
        return text^

    def get_int(self, key: String) raises -> Optional[Int64]:
        var value = self.get(key)
        if not value or value.value().kind() == 5:
            return None
        try:
            return jsonb_to_i64(value.value())
        except error:
            raise Error("Failed to convert to integer: " + String(error))

    def get_float(self, key: String) raises -> Optional[Float64]:
        var value = self.get(key)
        if not value or value.value().kind() == 5:
            return None
        try:
            return jsonb_to_f64(value.value())
        except error:
            raise Error("Failed to convert to float: " + String(error))

    def get_bool(self, key: String) raises -> Optional[Bool]:
        var value = self.get(key)
        if not value or value.value().kind() == 5:
            return None
        try:
            return jsonb_to_bool(value.value())
        except error:
            raise Error("Failed to convert to boolean: " + String(error))

    def array_contains(self, path: String, needle: String) raises -> Bool:
        var parsed = self._path(path)
        var values: List[JsonbValue]
        try:
            values = self.selector.select_values(parsed)
        except error:
            raise Error("Failed to check array contains at path '" + path + "': " + String(error))
        var budget = self._budget()
        # Preserve source's deliberately unescaped quoted-string alternative.
        var quoted = "\"" + needle + "\""
        for value in values:
            var index = UInt64(0)
            while True:
                budget.tick(Int(index) + 1)
                var element = jsonb_get_by_index(value, index)
                if not element:
                    break
                var text = self._text(element.value())
                budget.charge(text.byte_length())
                if text == needle or text == quoted:
                    return True
                index += 1
        return False

    def array_length(self, path: String) raises -> Optional[Int64]:
        var parsed = self._path(path)
        var values: List[JsonbValue]
        try:
            values = self.selector.select_values(parsed)
        except error:
            raise Error("Failed to get array length at path '" + path + "': " + String(error))
        if len(values) == 0:
            return None
        var budget = self._budget()
        var count = UInt64(0)
        while True:
            budget.tick(Int(count) + 1)
            var element = jsonb_get_by_index(values[0], count)
            if not element:
                break
            budget.charge(len(element.value()._data))
            count += 1
        # Valid nonarrays produce zero in the source, despite its UDF comment.
        return Int64(count)
