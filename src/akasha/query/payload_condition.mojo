"""Qdrant plain payload FieldCondition evaluation (Apache-2.0).

Ports condition_checker.rs and types.rs at
74f3e85b9473c62560006c043e13737ce6b48412. See THIRD_PARTY_NOTICES.md.
Query parsing is native; this module does not implement indexed text tokenizers.
"""
from akasha.document.value import PayloadValue
from akasha.document.json_path import JsonPath
from akasha.document.datetime import DateTimeValue
from akasha.document.chrono_tables import is_whitespace
from akasha.document.geo import GeoPoint, haversine_coordinates


def _number(value: PayloadValue) raises -> Float64:
    if value.is_floating():
        return value.as_float()
    if value.is_integer():
        return Float64(value.as_int())
    if value.is_unsigned():
        return Float64(value.as_uint())
    raise Error("range and geo coordinates require JSON numbers")


def _is_number(value: PayloadValue) -> Bool:
    return value.is_integer() or value.is_unsigned() or value.is_floating()


def _uint(value: PayloadValue) raises -> UInt64:
    if value.is_unsigned():
        return value.as_uint()
    if value.is_integer() and value.as_int() >= 0:
        return UInt64(value.as_int())
    raise Error("count requires an unsigned integer")


def _i64(value: PayloadValue) raises -> Optional[Int64]:
    if value.is_integer():
        return Optional(value.as_int())
    if value.is_unsigned() and value.as_uint() <= UInt64(0x7fff_ffff_ffff_ffff):
        return Optional(Int64(value.as_uint()))
    return None


def _required(value: PayloadValue, key: String) raises -> PayloadValue:
    var item = value.get_key(key)
    if not item:
        raise Error("missing required field condition property: " + key)
    return item.value().clone()


def _known_keys(value: PayloadValue, allowed: List[String]) raises:
    if not value.is_object():
        raise Error("field condition requires an object")
    var keys = value.keys()
    for key in keys:
        var found = False
        for option in allowed:
            if key == option:
                found = True
        if not found:
            raise Error("unsupported field condition property: " + key)


def _optional(value: PayloadValue, key: String) -> Optional[PayloadValue]:
    var item = value.get_key(key)
    if item and not item.value().is_null():
        return item^
    return None


struct _Match(Movable):
    var kind: String
    var values: List[PayloadValue]
    var tokens: List[String]

    def __init__(out self, spec: PayloadValue) raises:
        _known_keys(spec, ["value", "any", "except", "text", "text_any", "phrase", "prefix"])
        var keys = spec.keys()
        if len(keys) != 1:
            raise Error("match requires exactly one variant")
        self.kind = keys[0].copy()
        self.values = []
        self.tokens = []
        var value = _required(spec, self.kind)
        if self.kind == "any" or self.kind == "except":
            if not value.is_array():
                raise Error("match any/except requires a homogeneous string or integer array")
            self.values = value.children()
            var strings = len(self.values) == 0 or self.values[0].is_string()
            for i in range(len(self.values)):
                if (strings and not self.values[i].is_string()) or (not strings and not _i64(self.values[i])):
                    raise Error("match any/except requires a homogeneous string or integer array")
        elif self.kind == "value":
            if not (value.is_string() or value.is_boolean() or Bool(_i64(value))):
                raise Error("match value requires a string, bool or Int64")
            self.values.append(value^)
        else:
            if not value.is_string():
                raise Error("text match requires a string")
            var text = value.as_string()
            if self.kind == "text_any":
                var token = String()
                for cp in text.codepoints():
                    var character = String(cp)
                    var whitespace = is_whitespace(Int(cp))
                    if whitespace:
                        if token.byte_length() != 0:
                            self.tokens.append(token^)
                            token = String()
                    else:
                        token += character
                if token.byte_length() != 0:
                    self.tokens.append(token^)
            else:
                self.tokens.append(text^)

    def __init__(out self, *, copy: Self):
        self.kind = copy.kind.copy()
        self.values = []
        for i in range(len(copy.values)):
            self.values.append(copy.values[i].clone())
        self.tokens = copy.tokens.copy()

    def check(self, stored: PayloadValue) raises -> Bool:
        if self.kind == "value" or self.kind == "any" or self.kind == "except":
            var found = False
            for i in range(len(self.values)):
                ref value = self.values[i]
                if value.is_string() and stored.is_string():
                    found = value.as_string() == stored.as_string()
                elif value.is_boolean() and stored.is_boolean():
                    found = value.as_bool() == stored.as_bool()
                elif _i64(value) and _i64(stored):
                    found = _i64(value).value() == _i64(stored).value()
                if found:
                    break
            return not stored.is_null() and not found if self.kind == "except" else found
        if not stored.is_string():
            return False
        var text = stored.as_string()
        for token in self.tokens:
            if self.kind == "prefix":
                return text.startswith(token)
            if token in text:
                return True
        return False


@fieldwise_init
struct _Bound(Copyable, Movable):
    var operation: UInt8
    var number: Float64
    var count: UInt64
    var date: DateTimeValue


struct _Range(Copyable, Movable):
    # Numeric=1, datetime=2, value count=3. Bounds retain native precision.
    var kind: UInt8
    var bounds: List[_Bound]

    def __init__(out self, spec: PayloadValue, count: Bool = False) raises:
        _known_keys(spec, ["lt", "gt", "lte", "gte"])
        self.kind = 3 if count else 1
        self.bounds = []
        var names: List[String] = ["lt", "gt", "lte", "gte"]
        if not count:
            for key in names:
                var value = _optional(spec, key)
                if value and value.value().is_string():
                    self.kind = 2
        for i in range(len(names)):
            var value = _optional(spec, names[i])
            if not value:
                continue
            var bound = _Bound(UInt8(i), 0, 0, DateTimeValue(0, 0))
            if self.kind == 1:
                bound.number = _number(value.value())
            elif self.kind == 2:
                bound.date = DateTimeValue.from_payload(value.value())
            else:
                bound.count = _uint(value.value())
            self.bounds.append(bound^)

    def check_count(self, count: UInt64) -> Bool:
        for bound in self.bounds:
            if not _ordered(count < bound.count, count > bound.count, bound.operation):
                return False
        return True

    def check(self, stored: PayloadValue) raises -> Bool:
        if self.kind == 3:
            var count = UInt64(0 if stored.is_null() else 1)
            if stored.is_array():
                count = UInt64(len(stored.children()))
            return self.check_count(count)
        if self.kind == 1:
            if not _is_number(stored):
                return False
            var number = _number(stored)
            for bound in self.bounds:
                if not _ordered(number < bound.number, number > bound.number, bound.operation):
                    return False
            return True
        if not stored.is_string():
            return False
        var date: DateTimeValue
        try:
            date = DateTimeValue.from_payload(stored)
        except:
            return False
        for bound in self.bounds:
            var less = date.seconds < bound.date.seconds or (date.seconds == bound.date.seconds and date.nanoseconds < bound.date.nanoseconds)
            var greater = date.seconds > bound.date.seconds or (date.seconds == bound.date.seconds and date.nanoseconds > bound.date.nanoseconds)
            if not _ordered(less, greater, bound.operation):
                return False
        return True


def _ordered(less: Bool, greater: Bool, operation: UInt8) -> Bool:
    if operation == 0:
        return less
    if operation == 1:
        return greater
    if operation == 2:
        return not greater
    return not less


struct PayloadCondition(Movable):
    """Validated native field condition with Qdrant JSON-path semantics."""
    var key: JsonPath
    var _match: Optional[_Match]
    var _range: Optional[_Range]
    var _count: Optional[_Range]
    var _empty: Optional[Bool]
    var _null: Optional[Bool]
    var _top_left: Optional[GeoPoint]
    var _bottom_right: Optional[GeoPoint]
    var _center: Optional[GeoPoint]
    var _radius: Float64

    def __init__(out self, spec: PayloadValue) raises:
        _known_keys(spec, ["kind", "key", "match", "range", "values_count", "is_empty", "is_null", "geo_bounding_box", "geo_radius"])
        var key = _required(spec, "key")
        if not key.is_string():
            raise Error("field key requires a JSON path string")
        self.key = JsonPath.parse(key.as_string())
        self._match = None
        self._range = None
        self._count = None
        self._empty = None
        self._null = None
        self._top_left = None
        self._bottom_right = None
        self._center = None
        self._radius = 0
        var value = _optional(spec, "match")
        if value:
            self._match = Optional(_Match(value.value()))
        value = _optional(spec, "range")
        if value:
            self._range = Optional(_Range(value.value()))
        value = _optional(spec, "values_count")
        if value:
            self._count = Optional(_Range(value.value(), True))
        value = _optional(spec, "is_empty")
        if value:
            self._empty = Optional(value.value().as_bool())
        value = _optional(spec, "is_null")
        if value:
            self._null = Optional(value.value().as_bool())
        value = _optional(spec, "geo_bounding_box")
        if value:
            _known_keys(value.value(), ["top_left", "bottom_right"])
            self._top_left = Optional(GeoPoint.from_payload(_required(value.value(), "top_left")))
            self._bottom_right = Optional(GeoPoint.from_payload(_required(value.value(), "bottom_right")))
        value = _optional(spec, "geo_radius")
        if value:
            _known_keys(value.value(), ["center", "radius"])
            self._center = Optional(GeoPoint.from_payload(_required(value.value(), "center")))
            self._radius = _number(_required(value.value(), "radius"))
        if not (Bool(self._match) or Bool(self._range) or Bool(self._count) or Bool(self._empty) or Bool(self._null) or Bool(self._top_left) or Bool(self._center)):
            raise Error("at least one field condition must be specified")

    def __init__(out self, *, copy: Self):
        self.key = copy.key.copy()
        self._match = None
        if copy._match:
            self._match = Optional(_Match(copy=copy._match.value()))
        self._range = copy._range.copy()
        self._count = copy._count.copy()
        self._empty = copy._empty
        self._null = copy._null
        self._top_left = copy._top_left.copy()
        self._bottom_right = copy._bottom_right.copy()
        self._center = copy._center.copy()
        self._radius = copy._radius

    def clone(self) -> PayloadCondition:
        return PayloadCondition(copy=self)

    def check_empty(self) -> Bool:
        if self._count:
            return self._count.value().check_count(0)
        if self._empty:
            return self._empty.value()
        if self._null:
            return not self._null.value()
        return False

    def check(self, stored: PayloadValue) raises -> Bool:
        # Source override precedence is intentional, even with other predicates.
        if self._count:
            return self._count.value().check(stored)
        if self._empty:
            var empty = stored.is_null()
            if stored.is_array():
                empty = len(stored.children()) == 0
            return empty == self._empty.value()
        if self._null:
            var is_null = stored.is_null()
            if stored.is_array():
                var values = stored.children()
                for i in range(len(values)):
                    is_null = is_null or values[i].is_null()
            return is_null == self._null.value()
        if stored.is_array():
            var values = stored.children()
            for i in range(len(values)):
                if self._check_match(values[i]):
                    return True
            return False
        return self._check_match(stored)

    def _check_match(self, stored: PayloadValue) raises -> Bool:
        if self._match and self._match.value().check(stored):
            return True
        if self._range and self._range.value().check(stored):
            return True
        if not (Bool(self._top_left) or Bool(self._center)) or not stored.is_object():
            return False
        var lon = stored.get_key("lon")
        var lat = stored.get_key("lat")
        if not lon or not lat or not _is_number(lon.value()) or not _is_number(lat.value()):
            return False
        var x = _number(lon.value())
        var y = _number(lat.value())
        # Qdrant constructs unchecked payload coordinates; only query points
        # undergo GeoPoint validation. Array [lon,lat] is not a stored geo point.
        if self._center:
            ref center = self._center.value()
            if haversine_coordinates(center.lon, center.lat, x, y) < self._radius:
                return True
        if self._top_left:
            ref left = self._top_left.value()
            ref right = self._bottom_right.value()
            var longitude = (x > left.lon or x < right.lon) if left.lon > right.lon else (left.lon < x and x < right.lon)
            return longitude and right.lat < y and y < left.lat
        return False
