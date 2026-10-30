"""Typed keys for Lance's five JSON scalar-index targets.

Port: Lance OrderableScalarValue (Apache-2.0), DataFusion ScalarValue equality
(Apache-2.0), Rust core f64::total_cmp (MIT/Apache-2.0). Only equal target
types are comparable. Typed null sorts first; floating equality is bitwise.
"""
from std.memory import bitcast
from akasha.document.lance_json_result import LanceJsonResult


struct LanceScalarKey(Copyable, Movable):
    var target: UInt8
    var is_null: Bool
    var _integer: Int64
    var _bits: UInt64
    var _bytes: List[UInt8]

    def __init__(out self, target: UInt8) raises:
        if target < 1 or target > 5:
            raise Error("unsupported Lance scalar target type")
        self.target = target
        self.is_null = True
        self._integer = 0
        self._bits = 0
        self._bytes = List[UInt8]()

    @staticmethod
    def null(target: UInt8) raises -> Self:
        return Self(target)

    @staticmethod
    def boolean(value: Bool) raises -> Self:
        var result = Self(1)
        result.is_null = False
        result._integer = Int64(1 if value else 0)
        return result^

    @staticmethod
    def integer(value: Int64) raises -> Self:
        var result = Self(2)
        result.is_null = False
        result._integer = value
        return result^

    @staticmethod
    def float_bits(value: UInt64) raises -> Self:
        var result = Self(3)
        result.is_null = False
        result._bits = value
        return result^

    @staticmethod
    def text(value: String) raises -> Self:
        if value.byte_length() > 64 * 1024 * 1024:
            raise Error("Lance scalar byte limit exceeded")
        var result = Self(4)
        result.is_null = False
        for byte in value.as_bytes():
            result._bytes.append(byte)
        return result^

    @staticmethod
    def binary(var value: List[UInt8]) raises -> Self:
        if len(value) > 64 * 1024 * 1024:
            raise Error("Lance scalar byte limit exceeded")
        var result = Self(5)
        result.is_null = False
        result._bytes = value^
        return result^

    @staticmethod
    def from_json_result(value: LanceJsonResult, target: UInt8) raises -> Self:
        var result = Self(target)
        # Explicit presence Bool prevents mixed SIMD-bool/Optional coercion:
        # a false left operand must not become a present Optional(False).
        if Bool(target == 1) and Bool(value.boolean):
            return Self.boolean(value.boolean.value())
        if Bool(target == 2) and Bool(value.integer):
            return Self.integer(value.integer.value())
        if Bool(target == 3) and Bool(value.floating):
            return Self.float_bits(bitcast[DType.uint64](value.floating.value()))
        if Bool(target == 4) and Bool(value.text):
            return Self.text(value.text.value())
        if Bool(target == 5) and Bool(value.binary):
            return Self.binary(value.binary.value()._data.copy())
        if value.valid(0):
            raise Error("JSON result does not match Lance scalar target")
        return result^

    def validate(self, target: UInt8) raises:
        if target < 1 or target > 5 or self.target != target:
            raise Error("Lance scalar target type mismatch")

    def compare(self, other: Self) raises -> Int:
        self.validate(other.target)
        return self._compare_same(other)

    def _compare_same(self, other: Self) -> Int:
        # Internal sorting calls this only after validating the entire input.
        if self.is_null or other.is_null:
            return 0 if self.is_null == other.is_null else -1 if self.is_null else 1
        if self.target <= 2:
            return -1 if self._integer < other._integer else 1 if self._integer > other._integer else 0
        if self.target == 3:
            # Rust f64::total_cmp: invert the magnitude bits of negative values,
            # then compare as signed integers. Do not canonicalize NaNs or zero.
            var left = bitcast[DType.int64](self._bits)
            var right = bitcast[DType.int64](other._bits)
            left ^= Int64(UInt64(left >> 63) >> 1)
            right ^= Int64(UInt64(right >> 63) >> 1)
            return -1 if left < right else 1 if left > right else 0
        for i in range(min(len(self._bytes), len(other._bytes))):
            if self._bytes[i] != other._bytes[i]:
                return -1 if self._bytes[i] < other._bytes[i] else 1
        return -1 if len(self._bytes) < len(other._bytes) else 1 if len(self._bytes) > len(other._bytes) else 0
