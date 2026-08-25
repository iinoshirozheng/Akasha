from std.math import isfinite


comptime _STRING_KIND = UInt8(1)
comptime _INT_KIND = UInt8(2)
comptime _FLOAT_KIND = UInt8(3)
comptime _BOOL_KIND = UInt8(4)


struct PayloadValue(Movable):
    """A flat schemaless payload value with an explicit stable type tag."""

    var _kind: UInt8
    var _string_value: String
    var _int_value: Int64
    var _float_value: Float64
    var _bool_value: Bool

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

    def kind(self) -> UInt8:
        return self._kind

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

    def clone(self) -> PayloadValue:
        return PayloadValue(
            self._kind,
            String(copy=self._string_value),
            self._int_value,
            self._float_value,
            self._bool_value,
        )
