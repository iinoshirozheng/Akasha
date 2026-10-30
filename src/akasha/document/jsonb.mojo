# Adapted from jsonb 0.5.6, Copyright 2023 Datafuse Labs, Apache-2.0.
# core/databend/{constants,jentry,ser,de,builder,util}.rs.
# This module owns a logical JSONB body, independent of an outer nullable slot.
from std.math import isfinite, isnan
from std.memory import bitcast


comptime _SCALAR = UInt32(0x20000000)
comptime _ARRAY = UInt32(0x80000000)
comptime _OBJECT = UInt32(0x40000000)
comptime _TYPE = UInt32(0x70000000)
comptime _LENGTH = UInt32(0x0FFFFFFF)
comptime _MAX_BYTES = 16 * 1024 * 1024
comptime _MAX_NODES = 65_536
comptime _MAX_DEPTH = 64


def _read_be(bytes: Span[UInt8, _], offset: Int, size: Int) raises -> UInt64:
    if offset < 0 or size < 0 or size > 8 or offset > len(bytes) or size > len(bytes) - offset:
        raise Error("JSONB integer exceeds buffer bounds")
    var value = UInt64(0)
    for i in range(size):
        value = (value << 8) | UInt64(bytes[offset + i])
    return value


def _append_be(mut bytes: List[UInt8], value: UInt64, size: Int):
    for i in range(size):
        bytes.append(UInt8(value >> UInt64((size - i - 1) * 8)))


def _set_u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for i in range(4):
        bytes[offset + i] = UInt8(value >> UInt32((3 - i) * 8))


def _validate_atom(tag: UInt32, bytes: Span[UInt8, _]) raises:
    var size = len(bytes)
    if tag == 0 or tag == 0x30000000 or tag == 0x40000000:
        if size != 0:
            raise Error("JSONB null or boolean has a nonempty body")
    elif tag == 0x10000000:
        _ = String(from_utf8=bytes)
    elif tag == 0x20000000:
        if size == 0:
            raise Error("JSONB number has an empty body")
        var kind = bytes[0]
        if kind == 0 or kind == 0x10 or kind == 0x20 or kind == 0x30:
            if size != 1:
                raise Error("JSONB special number length is invalid")
        elif kind == 0x40 or kind == 0x50:
            if size != 2 and size != 3 and size != 5 and size != 9:
                raise Error("JSONB compact integer length is invalid")
        elif kind == 0x60:
            if size != 9:
                raise Error("JSONB floating length is invalid")
        elif kind == 0x70:
            # Upstream also reads the old precision-bearing Decimal128/256.
            if size != 10 and size != 18 and size != 19 and size != 34 and size != 35:
                raise Error("JSONB decimal length is invalid")
        else:
            raise Error("unknown JSONB number tag")
    elif tag == 0x60000000:
        if size == 0:
            raise Error("JSONB extension has an empty body")
        var kind = bytes[0]
        if kind == 0:
            return
        if ((kind == 0x10 and size == 5) or (kind == 0x20 and size == 9)
            or (kind == 0x30 and (size == 10 or size == 13))
            or (kind == 0x40 and size == 17)):
            return
        raise Error("invalid JSONB extension tag or length")
    else:
        raise Error("unknown JSONB entry tag")


def _validate(bytes: Span[UInt8, _], depth: Int, mut nodes: Int, mut deepest: Int) raises:
    nodes += 1
    if nodes > _MAX_NODES:
        raise Error("JSONB node count exceeds limit")
    var header = UInt32(_read_be(bytes, 0, 4))
    var kind = header & UInt32(0xE0000000)
    var count = Int(header & UInt32(0x1FFFFFFF))
    var entries = count
    if kind == _SCALAR:
        if count != 0:
            raise Error("JSONB scalar header has reserved bits")
        entries = 1
    elif kind == _ARRAY or kind == _OBJECT:
        if depth >= _MAX_DEPTH:
            raise Error("JSONB nesting depth exceeds limit")
        deepest = max(deepest, depth + 1)
        if count > _MAX_NODES - nodes:
            raise Error("JSONB child count exceeds node limit")
        if kind == _OBJECT:
            entries *= 2
    else:
        raise Error("unknown JSONB container header")
    if entries > (len(bytes) - 4) // 4:
        raise Error("JSONB entry table exceeds buffer bounds")
    var position = 4 + entries * 4
    var keys = Dict[String, Bool]()
    for i in range(entries):
        var entry = UInt32(_read_be(bytes, 4 + i * 4, 4))
        if entry & UInt32(0x80000000):
            raise Error("JSONB offset-mode entries are unsupported by the source format")
        var tag = entry & _TYPE
        var size = Int(entry & _LENGTH)
        if size > len(bytes) - position:
            raise Error("JSONB entry body exceeds buffer bounds")
        var is_key = kind == _OBJECT and i < count
        if is_key:
            if tag != 0x10000000:
                raise Error("JSONB object key is not a string")
            var key = String(from_utf8=bytes[position:position + size])
            if key in keys:
                raise Error("duplicate JSONB object key")
            keys[key] = True
        elif tag == 0x50000000:
            if kind == _SCALAR:
                raise Error("JSONB scalar cannot wrap a container")
            var nested = UInt32(_read_be(bytes, position, 4)) & UInt32(0xE0000000)
            if nested != _ARRAY and nested != _OBJECT:
                raise Error("JSONB container entry must contain an array or object")
            _validate(bytes[position:position + size], depth + 1, nodes, deepest)
        else:
            if kind != _SCALAR:
                nodes += 1
                if nodes > _MAX_NODES:
                    raise Error("JSONB node count exceeds limit")
            _validate_atom(tag, bytes[position:position + size])
        position += size
    if position != len(bytes):
        raise Error("unexpected trailing JSONB bytes")


struct JsonbValue(Copyable, Movable):
    """Owned databend JSONB, with source encodings and a checked native boundary.

    A JsonbValue containing JSON null is valid. Use an independent nullable slot
    for storage null. Text parsing, database storage and Arrow JSON are separate
    integration layers; plain PayloadValue behavior is not changed here.
    """
    comptime MAX_BYTES = _MAX_BYTES
    comptime MAX_NODES = _MAX_NODES
    comptime MAX_DEPTH = _MAX_DEPTH

    var _data: List[UInt8]
    var _node_count: Int
    var _depth: Int

    def __init__(out self, bytes: Span[UInt8, _]) raises:
        if len(bytes) > Self.MAX_BYTES:
            raise Error("JSONB byte size exceeds limit")
        var nodes = 0
        var depth = 0
        _validate(bytes, 0, nodes, depth)
        self._data = List[UInt8](capacity=len(bytes))
        for byte in bytes:
            self._data.append(byte)
        self._node_count = nodes
        self._depth = depth

    def clone(self) raises -> JsonbValue:
        return JsonbValue(Span(self._data))

    def to_bytes(self) -> List[UInt8]:
        return self._data.copy()

    @staticmethod
    def _scalar(tag: UInt32, body: Span[UInt8, _]) raises -> JsonbValue:
        if len(body) > Self.MAX_BYTES - 8:
            raise Error("JSONB byte size exceeds limit")
        var data = List[UInt8](capacity=8 + len(body))
        _append_be(data, UInt64(_SCALAR), 4)
        _append_be(data, UInt64(tag | UInt32(len(body))), 4)
        for byte in body:
            data.append(byte)
        return JsonbValue(Span(data))

    @staticmethod
    def null() raises -> JsonbValue:
        var empty = List[UInt8]()
        return JsonbValue._scalar(0, Span(empty))

    @staticmethod
    def boolean(value: Bool) raises -> JsonbValue:
        var empty = List[UInt8]()
        return JsonbValue._scalar(UInt32(0x40000000) if value else UInt32(0x30000000), Span(empty))

    @staticmethod
    def string(value: String) raises -> JsonbValue:
        return JsonbValue._scalar(0x10000000, value.as_bytes())

    @staticmethod
    def integer(value: Int64) raises -> JsonbValue:
        var body = List[UInt8]()
        if value == 0:
            body.append(0)
        else:
            body.append(0x40)
            var width = 8
            if value >= -128 and value <= 127:
                width = 1
            elif value >= -32768 and value <= 32767:
                width = 2
            elif value >= -2147483648 and value <= 2147483647:
                width = 4
            _append_be(body, bitcast[DType.uint64](value), width)
        return JsonbValue._scalar(0x20000000, Span(body))

    @staticmethod
    def unsigned(value: UInt64) raises -> JsonbValue:
        var body = List[UInt8]()
        if value == 0:
            body.append(0)
        else:
            body.append(0x50)
            var width = 8
            if value <= 255:
                width = 1
            elif value <= 65535:
                width = 2
            elif value <= 4294967295:
                width = 4
            _append_be(body, value, width)
        return JsonbValue._scalar(0x20000000, Span(body))

    @staticmethod
    def floating(value: Float64) raises -> JsonbValue:
        var body = List[UInt8]()
        if isnan(value):
            body.append(0x10)
        elif not isfinite(value):
            body.append(UInt8(0x30) if value < 0 else UInt8(0x20))
        else:
            body.append(0x60)
            _append_be(body, bitcast[DType.uint64](value), 8)
        return JsonbValue._scalar(0x20000000, Span(body))

    @staticmethod
    def decimal(unscaled_big_endian: Span[UInt8, _], scale: UInt8) raises -> JsonbValue:
        var width = len(unscaled_big_endian)
        if width != 8 and width != 16 and width != 32:
            raise Error("JSONB decimal requires 8, 16 or 32 unscaled bytes")
        var body: List[UInt8] = [0x70]
        for byte in unscaled_big_endian:
            body.append(byte)
        body.append(scale)
        return JsonbValue._scalar(0x20000000, Span(body))

    @staticmethod
    def binary(value: Span[UInt8, _]) raises -> JsonbValue:
        if len(value) > Self.MAX_BYTES - 9:
            raise Error("JSONB binary size exceeds limit")
        var body: List[UInt8] = [0]
        for byte in value:
            body.append(byte)
        return JsonbValue._scalar(0x60000000, Span(body))

    @staticmethod
    def date(days: Int32) raises -> JsonbValue:
        var body: List[UInt8] = [0x10]
        _append_be(body, UInt64(bitcast[DType.uint32](days)), 4)
        return JsonbValue._scalar(0x60000000, Span(body))

    @staticmethod
    def timestamp(micros: Int64) raises -> JsonbValue:
        var body: List[UInt8] = [0x20]
        _append_be(body, bitcast[DType.uint64](micros), 8)
        return JsonbValue._scalar(0x60000000, Span(body))

    @staticmethod
    def timestamp_tz(micros: Int64, offset_seconds: Int32) raises -> JsonbValue:
        var body: List[UInt8] = [0x30]
        _append_be(body, bitcast[DType.uint64](micros), 8)
        _append_be(body, UInt64(bitcast[DType.uint32](offset_seconds)), 4)
        return JsonbValue._scalar(0x60000000, Span(body))

    @staticmethod
    def interval(months: Int32, days: Int32, micros: Int64) raises -> JsonbValue:
        var body: List[UInt8] = [0x40]
        _append_be(body, UInt64(bitcast[DType.uint32](months)), 4)
        _append_be(body, UInt64(bitcast[DType.uint32](days)), 4)
        _append_be(body, bitcast[DType.uint64](micros), 8)
        return JsonbValue._scalar(0x60000000, Span(body))

    @staticmethod
    def array(values: List[JsonbValue]) raises -> JsonbValue:
        return JsonbValue._container(False, List[String](), values)

    @staticmethod
    def object(keys: List[String], values: List[JsonbValue]) raises -> JsonbValue:
        return JsonbValue._container(True, keys, values)

    @staticmethod
    def _container(object: Bool, keys: List[String], values: List[JsonbValue]) raises -> JsonbValue:
        var count = len(values)
        if count >= Self.MAX_NODES or (object and count != len(keys)):
            raise Error("JSONB container child count is invalid")
        var entries = count * (2 if object else 1)
        var size = 4 + entries * 4
        var nodes = 1
        var depth = 1
        for i in range(count):
            nodes += values[i]._node_count
            depth = max(depth, values[i]._depth + 1)
            size += len(values[i]._data) - (8 if values[i]._data[0] == 0x20 else 0)
            if object:
                size += keys[i].byte_length()
            if size > Self.MAX_BYTES or nodes > Self.MAX_NODES or depth > Self.MAX_DEPTH:
                raise Error("JSONB container exceeds resource limit")
        var order = List[Int]()
        var sorted_keys = keys.copy()
        if object:
            var indices = Dict[String, Int]()
            for i in range(count):
                if keys[i] in indices:
                    raise Error("duplicate JSONB object key")
                indices[keys[i]] = i
            sort(Span(sorted_keys))
            for key in sorted_keys:
                order.append(indices[key])
        else:
            for i in range(count):
                order.append(i)
        var data = List[UInt8](length=4 + entries * 4, fill=0)
        _set_u32(data, 0, (_OBJECT if object else _ARRAY) | UInt32(count))
        var entry = 4
        if object:
            for key in sorted_keys:
                _set_u32(data, entry, UInt32(0x10000000) | UInt32(key.byte_length()))
                entry += 4
                for byte in key.bytes():
                    data.append(byte)
        for i in order:
            ref child = values[i]._data
            var begin = 0
            var tag = UInt32(0x50000000) | UInt32(len(child))
            if child[0] == 0x20:
                tag = UInt32(_read_be(Span(child), 4, 4))
                begin = 8
            _set_u32(data, entry, tag)
            entry += 4
            for j in range(begin, len(child)):
                data.append(child[j])
        return JsonbValue(Span(data))

    def kind(self) -> Int:
        if self._data[0] == 0x80:
            return 6
        if self._data[0] == 0x40:
            return 7
        var tag = self._data[4] & UInt8(0x70)
        if tag == 0:
            return 5
        if tag == 0x10:
            return 1
        if tag == 0x30 or tag == 0x40:
            return 4
        var subtag = self._data[8]
        if tag == 0x60:
            return 10 + Int(subtag >> 4)
        if subtag == 0x40:
            return 2
        if subtag == 0 or subtag == 0x50:
            return 8
        if subtag == 0x70:
            return 9
        return 3

    def _require(self, expected: Int) raises:
        if self.kind() != expected:
            raise Error("JSONB value type mismatch")

    def as_string(self) raises -> String:
        self._require(1)
        return String(from_utf8=Span(self._data)[8:])

    def as_int(self) raises -> Int64:
        self._require(2)
        var width = len(self._data) - 9
        var raw = _read_be(Span(self._data), 9, width)
        if width < 8 and self._data[9] & UInt8(0x80):
            raw |= UInt64.MAX << UInt64(width * 8)
        return bitcast[DType.int64](raw)

    def as_uint(self) raises -> UInt64:
        self._require(8)
        return _read_be(Span(self._data), 9, len(self._data) - 9)

    def as_float(self) raises -> Float64:
        self._require(3)
        var tag = self._data[8]
        var bits = UInt64(0x7FF8000000000000)
        if tag == 0x20:
            bits = 0x7FF0000000000000
        elif tag == 0x30:
            bits = 0xFFF0000000000000
        elif tag == 0x60:
            bits = _read_be(Span(self._data), 9, 8)
        return bitcast[DType.float64](bits)

    def as_bool(self) raises -> Bool:
        self._require(4)
        return self._data[4] == 0x40

    def decimal_bytes(self) raises -> List[UInt8]:
        self._require(9)
        var width = len(self._data) - 10
        if width == 17 or width == 33:
            width -= 1
        var result = List[UInt8](capacity=width)
        for i in range(width):
            result.append(self._data[9 + i])
        return result^

    def decimal_scale(self) raises -> UInt8:
        self._require(9)
        return self._data[len(self._data) - 1]

    def as_binary(self) raises -> List[UInt8]:
        self._require(10)
        var result = List[UInt8](capacity=len(self._data) - 9)
        for i in range(9, len(self._data)):
            result.append(self._data[i])
        return result^

    def as_date(self) raises -> Int32:
        self._require(11)
        return bitcast[DType.int32](UInt32(_read_be(Span(self._data), 9, 4)))

    def as_timestamp(self) raises -> Int64:
        if self.kind() != 12 and self.kind() != 13:
            raise Error("JSONB value is not a timestamp")
        return bitcast[DType.int64](_read_be(Span(self._data), 9, 8))

    def timezone_offset(self) raises -> Int32:
        self._require(13)
        if len(self._data) == 18:
            return Int32(bitcast[DType.int8](self._data[17])) * 3600
        return bitcast[DType.int32](UInt32(_read_be(Span(self._data), 17, 4)))

    def as_interval(self) raises -> Tuple[Int32, Int32, Int64]:
        self._require(14)
        return (bitcast[DType.int32](UInt32(_read_be(Span(self._data), 9, 4))),
                bitcast[DType.int32](UInt32(_read_be(Span(self._data), 13, 4))),
                bitcast[DType.int64](_read_be(Span(self._data), 17, 8)))

    def _count(self) raises -> Int:
        if self.kind() != 6 and self.kind() != 7:
            raise Error("JSONB value is not a container")
        return Int(UInt32(_read_be(Span(self._data), 0, 4)) & UInt32(0x1FFFFFFF))

    def keys(self) raises -> List[String]:
        self._require(7)
        var count = self._count()
        var position = 4 + count * 8
        var keys = List[String](capacity=count)
        for i in range(count):
            var size = Int(UInt32(_read_be(Span(self._data), 4 + i * 4, 4)) & _LENGTH)
            keys.append(String(from_utf8=Span(self._data)[position:position + size]))
            position += size
        return keys^

    def children(self) raises -> List[JsonbValue]:
        var count = self._count()
        var object = self.kind() == 7
        var position = 4 + count * (8 if object else 4)
        var entry = 4
        if object:
            for i in range(count):
                position += Int(UInt32(_read_be(Span(self._data), 4 + i * 4, 4)) & _LENGTH)
            entry += count * 4
        var children = List[JsonbValue](capacity=count)
        for i in range(count):
            var tag = UInt32(_read_be(Span(self._data), entry + i * 4, 4))
            var size = Int(tag & _LENGTH)
            if tag & _TYPE == 0x50000000:
                children.append(JsonbValue(Span(self._data)[position:position + size]))
            else:
                children.append(JsonbValue._scalar(tag & _TYPE, Span(self._data)[position:position + size]))
            position += size
        return children^
