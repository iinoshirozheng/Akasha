"""jsonb 0.5.6 Number arithmetic/comparison (Datafuse Labs, Apache-2.0).

Fixed-width multiplication uses ethnum 1.5.3's native umulddi3/mul3 (MIT)
and Arrow 58.4.0's checked signed i256 multiplication (Apache-2.0).
The latter avoids importing division solely to detect multiplication overflow.
No number is serialized between expression operations: variant and zero sign
are part of the source contract, unlike canonical binary JSONB zero encoding.
"""
from std.math import isnan
from std.ffi import external_call
from std.memory import bitcast
from akasha.document.jsonb import JsonbValue, _read_be
from akasha.document.jsonb_formatting import _decimal_float, _read128


@fieldwise_init
struct _Wide(ImplicitlyCopyable):
    var high: UInt128
    var low: UInt128

    @staticmethod
    def signed(value: Int128) -> Self:
        return Self(UInt128.MAX if value < 0 else UInt128(0), bitcast[DType.uint128](value))

    def negative(self) -> Bool:
        return (self.high >> 127) != 0

    def zero(self) -> Bool:
        return self.high == 0 and self.low == 0

    def neg(self) -> Self:
        var low = UInt128(0) - self.low
        return Self(~self.high + UInt128(low == 0), low)

    def cmp(self, other: Self) -> Int:
        var a = bitcast[DType.int128](self.high)
        var b = bitcast[DType.int128](other.high)
        if a != b:
            return -1 if a < b else 1
        return -1 if self.low < other.low else (1 if self.low > other.low else 0)

    def mul(self, other: Self) -> Self:
        var result = _umul128(self.low, other.low)
        result.high += self.high * other.low + self.low * other.high
        return result

    def checked_mul(self, other: Self) -> Optional[Self]:
        # Arrow bigint::i256::checked_mul, retaining its signed-magnitude
        # multiplication and final sign-conversion check. The low product is
        # the equivalent ethnum native umulddi3 primitive already used above.
        if self.zero() or other.zero():
            return Self(0, 0)
        var negative = self.negative() != other.negative()
        var a = self.neg() if self.negative() else self
        var b = other.neg() if other.negative() else other
        if a.high != 0 and b.high != 0:
            return None
        var result = _umul128(a.low, b.low)
        var hl = _umul128(a.high, b.low)
        var lh = _umul128(a.low, b.high)
        if hl.high != 0 or lh.high != 0:
            return None
        var high = result.high + hl.low
        if high < result.high:
            return None
        var high2 = high + lh.low
        if high2 < high:
            return None
        result.high = high2
        if negative:
            result = result.neg()
        if result.negative() != negative:
            return None
        return result

    def pow(self, var exponent: Int) -> Self:
        # ethnum::I256::pow in the pinned release profile (wrapping multiply).
        if exponent == 0:
            return Self(0, 1)
        var base = self
        var accumulator = Self(0, 1)
        while exponent > 1:
            if exponent & 1:
                accumulator = accumulator.mul(base)
            exponent //= 2
            base = base.mul(base)
        return accumulator.mul(base)


def _umul128(a: UInt128, b: UInt128) -> _Wide:
    # ethnum native::mul::umulddi3, adapted from LLVM compiler-rt multi3.
    var mask = UInt128(UInt64.MAX)
    var low = (a & mask) * (b & mask)
    var t = low >> 64
    low &= mask
    t += (a >> 64) * (b & mask)
    low += (t & mask) << 64
    var high = t >> 64
    t = low >> 64
    low &= mask
    t += (b >> 64) * (a & mask)
    low += (t & mask) << 64
    high += t >> 64
    high += (a >> 64) * (b >> 64)
    return _Wide(high, low)


def _ordered_float_cmp(a: Float64, b: Float64) -> Int:
    # ordered-float 5.3.0: all NaNs equal, above +infinity; signed zeros equal.
    if isnan(a):
        return 0 if isnan(b) else 1
    if isnan(b):
        return -1
    return -1 if a < b else (1 if a > b else 0)


struct JsonbNumber(ImplicitlyCopyable):
    """Expression Number; Int64/UInt64/F64/Decimal64/128/256 tags are 0..5.

    Construct via the typed factories or from_value. Fixed-size coefficients
    own their data; methods preserve the original Number variant until to_value.
    """
    var kind: Int
    var value: _Wide
    var scale: UInt8

    def __init__(out self):
        self.kind = 0
        self.value = _Wide(0, 0)
        self.scale = 0

    @staticmethod
    def integer(value: Int64) -> Self:
        var result = Self()
        result.value = _Wide.signed(Int128(value))
        return result

    @staticmethod
    def unsigned(value: UInt64) -> Self:
        var result = Self()
        result.kind = 1
        result.value = _Wide(0, UInt128(value))
        return result

    @staticmethod
    def floating(value: Float64) -> Self:
        var result = Self()
        result.kind = 2
        result.value = _Wide(0, UInt128(bitcast[DType.uint64](value)))
        return result

    @staticmethod
    def decimal(bytes: Span[UInt8, _], scale: UInt8) raises -> Self:
        var result = Self()
        var width = len(bytes)
        if width == 8:
            result.kind = 3
            result.value = _Wide.signed(Int128(bitcast[DType.int64](_read_be(bytes, 0, 8))))
        elif width == 16:
            result.kind = 4
            result.value = _Wide.signed(bitcast[DType.int128](_read128(bytes, 0)))
        elif width == 32:
            result.kind = 5
            result.value = _Wide(_read128(bytes, 0), _read128(bytes, 16))
        else:
            raise Error("JSONB decimal requires 8, 16 or 32 unscaled bytes")
        result.scale = scale
        return result

    @staticmethod
    def from_value(value: JsonbValue) raises -> Self:
        var kind = value.kind()
        if kind == 2:
            return Self.integer(value.as_int())
        if kind == 8:
            return Self.unsigned(value.as_uint())
        if kind == 3:
            return Self.floating(value.as_float())
        if kind == 9:
            var bytes = value.decimal_bytes()
            return Self.decimal(Span(bytes), value.decimal_scale())
        raise Error("JSONB value is not a number")

    def coefficient_bytes(self) raises -> List[UInt8]:
        if self.kind < 3 or self.kind > 5:
            raise Error("JSONB number is not a decimal")
        var width = 8 << (self.kind - 3)
        var bytes = List[UInt8](capacity=width)
        for i in range(width):
            var shift = (width - 1 - i) * 8
            bytes.append(UInt8((self.value.high if shift >= 128 else self.value.low) >> UInt128(shift % 128)))
        return bytes^

    def to_value(self) raises -> JsonbValue:
        if self.kind == 0:
            return JsonbValue.integer(bitcast[DType.int64](UInt64(self.value.low)))
        if self.kind == 1:
            return JsonbValue.unsigned(UInt64(self.value.low))
        if self.kind == 2:
            return JsonbValue.floating(bitcast[DType.float64](UInt64(self.value.low)))
        var bytes = self.coefficient_bytes()
        return JsonbValue.decimal(Span(bytes), self.scale)

    def as_f64(self) raises -> Float64:
        if self.kind == 0:
            return Float64(bitcast[DType.int64](UInt64(self.value.low)))
        if self.kind == 1:
            return Float64(UInt64(self.value.low))
        if self.kind == 2:
            return bitcast[DType.float64](UInt64(self.value.low))
        var bytes: List[UInt8] = [0x70]
        var coefficient = self.coefficient_bytes()
        for byte in coefficient:
            bytes.append(byte)
        bytes.append(self.scale)
        return _decimal_float(Span(bytes))

    def cmp(self, other: Self) raises -> Int:
        if self.kind == 2 or other.kind == 2:
            return _ordered_float_cmp(self.as_f64(), other.as_f64())
        # Integers are signed-extended or zero-extended in the arena. Decimal
        # promotion in Number::cmp is therefore exact without rebuilding enums.
        if self.scale == other.scale:
            return self.value.cmp(other.value)
        var a = self.value
        var b = other.value
        var difference = Int(self.scale) - Int(other.scale)
        var power = _Wide(0, 10).pow(abs(difference))
        var wide = self.kind == 5 or other.kind == 5
        if not wide:
            # Rust i128::pow wraps BEFORE checked_mul in the source profile.
            power = _Wide.signed(bitcast[DType.int128](power.low))
        var adjusted = b.checked_mul(power) if difference > 0 else a.checked_mul(power)
        if adjusted:
            var value = adjusted.value()
            var fits = wide or value.high == (UInt128.MAX if bitcast[DType.int128](value.low) < 0 else UInt128(0))
            if fits:
                return a.cmp(value) if difference > 0 else value.cmp(b)
        return _ordered_float_cmp(self.as_f64(), other.as_f64())

    def neg(self) raises -> Self:
        if self.kind <= 1:
            var bits = UInt64(self.value.low)
            var integer = bitcast[DType.int64](bits)
            if (self.kind == 1 and bits > UInt64(Int64.MAX)) or integer == Int64.MIN:
                raise Error("Int64 overflow")
            return Self.integer(-integer)
        if self.kind == 2:
            return Self.floating(self.as_f64() * -1.0)
        var result = self
        if self.kind == 5:
            if self.value.high == UInt128(1) << 127 and self.value.low == 0:
                raise Error("Decimal256 overflow")
            result.value = self.value.neg()
        elif self.kind == 4:
            result.value = _Wide.signed(bitcast[DType.int128](UInt128(0) - self.value.low))
        else:
            result.value = _Wide.signed(Int128(bitcast[DType.int64](UInt64(0) - UInt64(self.value.low))))
        return result

    def add(self, other: Self) raises -> Self:
        return self._binary(other, 0)

    def sub(self, other: Self) raises -> Self:
        return self._binary(other, 1)

    def mul(self, other: Self) raises -> Self:
        return self._binary(other, 2)

    def div(self, other: Self) raises -> Self:
        return self._binary(other, 3)

    def rem(self, other: Self) raises -> Self:
        return self._binary(other, 4)

    def _binary(self, other: Self, op: Int) raises -> Self:
        if op == 3 or self.kind >= 2 or other.kind >= 2:
            var a = self.as_f64()
            var b = other.as_f64()
            if (op == 3 or op == 4) and b == 0:
                raise Error("Division by zero")
            if op == 0:
                return Self.floating(a + b)
            if op == 1:
                return Self.floating(a - b)
            if op == 2:
                return Self.floating(a * b)
            if op == 3:
                return Self.floating(a / b)
            # Rust's f64 remainder is truncating fmod. Mojo 1.0 `%` computes
            # floor modulo, while std.math.remainder uses nearest quotient;
            # neither has this contract. Use the same native libm primitive.
            return Self.floating(external_call["fmod", Float64](a, b))
        var abits = UInt64(self.value.low)
        var bbits = UInt64(other.value.low)
        var ai = bitcast[DType.int64](abits)
        var bi = bitcast[DType.int64](bbits)
        if op == 4 and bbits == 0:
            raise Error("Division by zero")
        var signed = op == 1 or (self.kind == 0 and other.kind == 0) or (self.kind == 0 and ai < 0) or (other.kind == 0 and bi < 0)
        if signed:
            var error = "UInt64 overflow" if op == 1 and self.kind == 1 and other.kind == 1 else "Int64 overflow"
            var a = Int128(ai)
            var b = Int128(bi)
            var value: Int128
            if op == 0:
                value = a + b
            elif op == 1:
                value = a - b
            elif op == 2:
                value = a * b
            else:
                if ai == Int64.MIN and bi == -1:
                    raise Error(error)
                # Rust checked_rem truncates quotient toward zero. Positive
                # magnitudes avoid Mojo's floor/modulo convention for signs.
                var magnitude = abs(a) % abs(b)
                value = -magnitude if a < 0 else magnitude
            if value < Int128(Int64.MIN) or value > Int128(Int64.MAX):
                raise Error(error)
            return Self.integer(Int64(value))
        var a = UInt128(abits)
        var b = UInt128(bbits)
        var value: UInt128
        if op == 0:
            value = a + b
        elif op == 2:
            value = a * b
        else:
            value = a % b
        if value > UInt128(UInt64.MAX):
            raise Error("UInt64 overflow")
        return Self.unsigned(UInt64(value))
