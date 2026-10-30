from std.math import isfinite
from std.memory import bitcast
from akasha.document.jsonb import JsonbValue


comptime _STRING_KIND = UInt8(1)
comptime _INT_KIND = UInt8(2)
comptime _FLOAT_KIND = UInt8(3)
comptime _BOOL_KIND = UInt8(4)
comptime _NULL_KIND = UInt8(5)
comptime _ARRAY_KIND = UInt8(6)
comptime _OBJECT_KIND = UInt8(7)
comptime _UINT_KIND = UInt8(8)
comptime _JSONB_KIND = UInt8(9)


@fieldwise_init
struct _ValueNode(Copyable, Movable):
    """Preorder representation adapter for serde_json's owned Value tree."""

    var kind: UInt8
    var text: String
    var integer: Int64
    var floating: Float64
    var boolean: Bool
    var unsigned: UInt64
    var key: String
    var end: Int
    var jsonb: Optional[JsonbValue]


struct PayloadValue(Movable):
    """An owned JSON value; scalar tags 1..4 retain their original meaning.

    Containers adapt serde_json Value/Map (Qdrant's preserve_order build) to
    a flat arena because Mojo 1.0 cannot own List[Self]. Scalar storage remains
    inline. Tree depth/nodes/bytes are bounded before publishing containers.
    """

    comptime MAX_DEPTH = 64
    comptime MAX_NODES = 65_536
    comptime MAX_BYTES = 16 * 1024 * 1024

    var _kind: UInt8
    var _string_value: String
    var _int_value: Int64
    var _float_value: Float64
    var _bool_value: Bool
    var _uint_value: UInt64
    var _nodes: List[_ValueNode]
    var _depth: Int
    var _jsonb_value: Optional[JsonbValue]

    def __init__(
        out self,
        kind: UInt8,
        var string_value: String,
        int_value: Int64,
        float_value: Float64,
        bool_value: Bool,
    ):
        self._kind = kind
        self._string_value = string_value^
        self._int_value = int_value
        self._float_value = float_value
        self._bool_value = bool_value
        self._uint_value = 0
        self._nodes = List[_ValueNode]()
        self._depth = 0
        self._jsonb_value = Optional[JsonbValue]()

    @staticmethod
    def string(value: String) -> PayloadValue:
        return PayloadValue(_STRING_KIND, String(copy=value), 0, 0.0, False)

    @staticmethod
    def integer(value: Int64) -> PayloadValue:
        return PayloadValue(_INT_KIND, String(), value, 0.0, False)

    @staticmethod
    def floating(value: Float64) raises -> PayloadValue:
        if not isfinite(value):
            raise Error("floating payload values must be finite")
        return PayloadValue(_FLOAT_KIND, String(), 0, value, False)

    @staticmethod
    def boolean(value: Bool) -> PayloadValue:
        return PayloadValue(_BOOL_KIND, String(), 0, 0.0, value)

    @staticmethod
    def null() -> PayloadValue:
        return PayloadValue(_NULL_KIND, String(), 0, 0.0, False)

    @staticmethod
    def unsigned(value: UInt64) -> PayloadValue:
        var result = PayloadValue(_UINT_KIND, String(), 0, 0.0, False)
        result._uint_value = value
        return result^

    @staticmethod
    def jsonb(var value: JsonbValue) -> PayloadValue:
        var result = PayloadValue(_JSONB_KIND, String(), 0, 0.0, False)
        result._depth = value._depth
        result._jsonb_value = Optional(value^)
        return result^

    @staticmethod
    def array(var values: List[PayloadValue]) raises -> PayloadValue:
        return PayloadValue._container(_ARRAY_KIND, List[String](), values^)

    @staticmethod
    def object(var keys: List[String], var values: List[PayloadValue]) raises -> PayloadValue:
        """serde_json Map insertion: last duplicate wins in its original slot.

        Object member keys include empty strings and NUL, as JSON permits.
        The document's top-level named-field contract is validated separately.
        """
        if len(keys) != len(values):
            raise Error("payload object keys and values must have equal lengths")
        if len(keys) >= Self.MAX_NODES:
            raise Error("payload node count exceeds limit")
        var slots = Dict[String, Int]()
        var unique = List[String]()
        var selected = List[Int]()
        for i in range(len(keys)):
            if keys[i] in slots:
                selected[slots[keys[i]]] = i
            else:
                slots[keys[i]] = len(unique)
                unique.append(String(copy=keys[i]))
                selected.append(i)
        var children = List[PayloadValue](capacity=len(unique))
        for i in selected:
            children.append(values[i].clone())
        return PayloadValue._container(_OBJECT_KIND, unique^, children^)

    @staticmethod
    def _container(kind: UInt8, var keys: List[String], var values: List[PayloadValue]) raises -> PayloadValue:
        var count = 1
        var arena_count = 1
        var depth = 1
        var content = 0
        for i in range(len(values)):
            count += values[i].node_count()
            arena_count += len(values[i]._nodes) if values[i].is_container() else 1
            if count > Self.MAX_NODES:
                raise Error("payload node count exceeds limit")
            depth = max(depth, 1 + values[i]._depth)
            content += values[i].content_bytes()
            if kind == _OBJECT_KIND:
                content += keys[i].byte_length()
            if content > Self.MAX_BYTES:
                raise Error("payload content exceeds size limit")
        if depth > Self.MAX_DEPTH:
            raise Error("payload nesting depth exceeds limit")
        var result = PayloadValue(kind, String(), 0, 0.0, False)
        result._depth = depth
        result._nodes.reserve(arena_count)
        result._nodes.append(_ValueNode(kind, String(), 0, 0.0, False, 0, String(), arena_count, Optional[JsonbValue]()))
        for i in range(len(values)):
            var offset = len(result._nodes)
            ref value = values[i]
            if value.is_container():
                for node in value._nodes:
                    var copied = node.copy()
                    copied.end += offset
                    result._nodes.append(copied^)
            else:
                result._nodes.append(_ValueNode(value._kind, String(copy=value._string_value),
                    value._int_value, value._float_value, value._bool_value, value._uint_value,
                    String(), offset + 1, value._jsonb_value.copy()))
            if kind == _OBJECT_KIND:
                result._nodes[offset].key = String(copy=keys[i])
        return result^

    def kind(self) -> UInt8:
        return self._kind

    def is_string(self) -> Bool:
        return self._kind == _STRING_KIND

    def is_integer(self) -> Bool:
        return self._kind == _INT_KIND

    def is_floating(self) -> Bool:
        return self._kind == _FLOAT_KIND

    def is_boolean(self) -> Bool:
        return self._kind == _BOOL_KIND

    def is_null(self) -> Bool:
        return self._kind == _NULL_KIND

    def is_array(self) -> Bool:
        return self._kind == _ARRAY_KIND

    def is_object(self) -> Bool:
        return self._kind == _OBJECT_KIND

    def is_unsigned(self) -> Bool:
        return self._kind == _UINT_KIND

    def is_jsonb(self) -> Bool:
        return self._kind == _JSONB_KIND

    def is_container(self) -> Bool:
        return self.is_array() or self.is_object()

    def node_count(self) -> Int:
        if self.is_jsonb():
            return self._jsonb_value.value()._node_count
        if not self.is_container():
            return 1
        var count = len(self._nodes)
        for node in self._nodes:
            if node.kind == _JSONB_KIND:
                count += node.jsonb.value()._node_count - 1
        return count

    def content_bytes(self) -> Int:
        if self.is_container():
            var total = 0
            for node in self._nodes:
                total += node.key.byte_length()
                if node.kind == _STRING_KIND:
                    total += node.text.byte_length()
                elif node.kind == _JSONB_KIND:
                    total += len(node.jsonb.value()._data)
                elif node.kind <= _BOOL_KIND or node.kind == _UINT_KIND:
                    total += 8
            return total
        if self.is_jsonb():
            return len(self._jsonb_value.value()._data)
        return self._string_value.byte_length() if self.is_string() else (0 if self.is_null() else 8)

    def children(self) raises -> List[PayloadValue]:
        if not self.is_container():
            raise Error("payload value is not a container")
        var result = List[PayloadValue]()
        var i = 1
        while i < len(self._nodes):
            result.append(self._subtree(i))
            i = self._nodes[i].end
        return result^

    def keys(self) raises -> List[String]:
        if not self.is_object():
            raise Error("payload value is not an object")
        var result = List[String]()
        var i = 1
        while i < len(self._nodes):
            result.append(String(copy=self._nodes[i].key))
            i = self._nodes[i].end
        return result^

    def get_key(self, key: String) -> Optional[PayloadValue]:
        if self.is_object():
            var i = 1
            while i < len(self._nodes):
                if self._nodes[i].key == key:
                    return Optional(self._subtree(i))
                i = self._nodes[i].end
        return Optional[PayloadValue]()

    def get_index(self, index: UInt64) -> Optional[PayloadValue]:
        if self.is_array():
            var i = 1
            var ordinal = UInt64(0)
            while i < len(self._nodes):
                if ordinal == index:
                    return Optional(self._subtree(i))
                ordinal += 1
                i = self._nodes[i].end
        return Optional[PayloadValue]()

    def _subtree(self, index: Int) -> PayloadValue:
        ref node = self._nodes[index]
        var result = PayloadValue(node.kind, String(copy=node.text), node.integer, node.floating, node.boolean)
        result._uint_value = node.unsigned
        result._jsonb_value = node.jsonb.copy()
        if result.is_jsonb():
            result._depth = result._jsonb_value.value()._depth
        if result.is_container():
            var ends = List[Int]()
            for i in range(index, node.end):
                while len(ends) > 0 and ends[len(ends) - 1] <= i:
                    _ = ends.pop()
                if self._nodes[i].kind == _ARRAY_KIND or self._nodes[i].kind == _OBJECT_KIND:
                    ends.append(self._nodes[i].end)
                    result._depth = max(result._depth, len(ends))
                elif self._nodes[i].kind == _JSONB_KIND:
                    result._depth = max(result._depth, len(ends) + self._nodes[i].jsonb.value()._depth)
                var copied = self._nodes[i].copy()
                copied.end -= index
                result._nodes.append(copied^)
            result._nodes[0].key = String()
        return result^

    def as_string(self) raises -> String:
        if self._kind != _STRING_KIND:
            raise Error("payload value is not a string")
        return String(copy=self._string_value)

    def as_int(self) raises -> Int64:
        if self._kind != _INT_KIND:
            raise Error("payload value is not an integer")
        return self._int_value

    def as_float(self) raises -> Float64:
        if self._kind != _FLOAT_KIND:
            raise Error("payload value is not a float")
        return self._float_value

    def as_bool(self) raises -> Bool:
        if self._kind != _BOOL_KIND:
            raise Error("payload value is not a bool")
        return self._bool_value

    def as_uint(self) raises -> UInt64:
        if not self.is_unsigned():
            raise Error("payload value is not an unsigned integer")
        return self._uint_value

    def as_jsonb(self) raises -> JsonbValue:
        if not self.is_jsonb():
            raise Error("payload value is not JSONB")
        return self._jsonb_value.value().copy()

    def clone(self) -> PayloadValue:
        var result = PayloadValue(
            self._kind,
            String(copy=self._string_value),
            self._int_value,
            self._float_value,
            self._bool_value,
        )
        result._uint_value = self._uint_value
        result._nodes = self._nodes.copy()
        result._depth = self._depth
        result._jsonb_value = self._jsonb_value.copy()
        return result^

    def same_representation(self, other: PayloadValue) -> Bool:
        """Typed, ordered bit equality, including signed floating zero."""
        if self._kind != other._kind:
            return False
        if self.is_container():
            if len(self._nodes) != len(other._nodes):
                return False
            for i in range(len(self._nodes)):
                ref a = self._nodes[i]
                ref b = other._nodes[i]
                if (a.kind != b.kind or a.key != b.key or a.end != b.end
                    or a.text != b.text or a.integer != b.integer
                    or a.unsigned != b.unsigned or a.boolean != b.boolean
                    or not _same_jsonb(a.jsonb, b.jsonb)
                    or bitcast[DType.uint64](a.floating) != bitcast[DType.uint64](b.floating)):
                    return False
            return True
        return (self._string_value == other._string_value
            and self._int_value == other._int_value and self._uint_value == other._uint_value
            and self._bool_value == other._bool_value
            and _same_jsonb(self._jsonb_value, other._jsonb_value)
            and bitcast[DType.uint64](self._float_value) == bitcast[DType.uint64](other._float_value))


def _same_jsonb(left: Optional[JsonbValue], right: Optional[JsonbValue]) -> Bool:
    if Bool(left) != Bool(right):
        return False
    return not left or left.value()._data == right.value()._data
