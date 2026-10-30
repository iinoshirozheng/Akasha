"""jsonb 0.5.6 Number arithmetic/comparison (Datafuse Labs, Apache-2.0).

Fixed-width multiplication and unsigned division use ethnum 1.5.3's native
primitives (MIT); checked signed multiplication follows Arrow 58.4.0
(Apache-2.0). Source exact/rounded conversions share these fixed-width words.
No number is serialized between expression operations: variant and zero sign
are part of the source contract, unlike canonical binary JSONB zero encoding.
"""
from std.math import isnan, isfinite
from std.bit import count_leading_zeros
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


def _udiv256_128(high: UInt128, low: UInt128, var divisor: UInt128) -> Tuple[UInt128, UInt128]:
    # ethnum: caller guarantees 0 <= high < divisor. Normalize into base 2^64.
    var base = UInt128(1) << 64
    var shift = Int(count_leading_zeros(divisor))
    var top = high
    var bottom = low
    if shift > 0:
        divisor <<= UInt128(shift)
        top = (high << UInt128(shift)) | (low >> UInt128(128 - shift))
        bottom = low << UInt128(shift)
    var divisor_high = divisor >> 64
    var divisor_low = divisor & UInt128(UInt64.MAX)
    var bottom_high = bottom >> 64
    var bottom_low = bottom & UInt128(UInt64.MAX)
    var q1 = top // divisor_high
    var remainder = top - q1 * divisor_high
    while q1 >= base or q1 * divisor_low > base * remainder + bottom_high:
        q1 -= 1
        remainder += divisor_high
        if remainder >= base:
            break
    var middle = top * base + bottom_high - q1 * divisor
    var q0 = middle // divisor_high
    remainder = middle - q0 * divisor_high
    while q0 >= base or q0 * divisor_low > base * remainder + bottom_low:
        q0 -= 1
        remainder += divisor_high
        if remainder >= base:
            break
    remainder = (middle * base + bottom_low - q0 * divisor) >> UInt128(shift)
    return (q1 * base + q0, remainder)


def _wide_div128(value: _Wide, divisor: UInt128) raises -> Tuple[_Wide, UInt128]:
    if divisor == 0:
        raise Error("wide division by zero")
    if value.high == 0:
        return (_Wide(0, value.low // divisor), value.low % divisor)
    # ethnum udivmod4: high-word division before the two-digit primitive.
    var high = value.high // divisor
    var low, remainder = _udiv256_128(value.high % divisor, value.low, divisor)
    return (_Wide(high, low), remainder)


def _unsigned_cmp(a: _Wide, b: _Wide) -> Int:
    if a.high != b.high:
        return -1 if a.high < b.high else 1
    return -1 if a.low < b.low else (1 if a.low > b.low else 0)


def _sub_carry(a: UInt128, b: UInt128, carry: Bool) -> Tuple[UInt128, Bool]:
    var right = b + UInt128(carry)
    return (a - right, right < b or a < right)


def _add_carry(a: UInt128, b: UInt128, carry: Bool) -> Tuple[UInt128, Bool]:
    var right = b + UInt128(carry)
    var result = a + right
    return (result, right < b or result < a)


def _unsigned_sub(a: _Wide, b: _Wide) -> _Wide:
    return _Wide(a.high - b.high - UInt128(a.low < b.low), a.low - b.low)


def _wide_divmod(value: _Wide, divisor: _Wide) raises -> Tuple[_Wide, _Wide]:
    """ethnum udivmod4/div_mod_knuth, with unsigned two-word inputs."""
    if divisor.zero():
        raise Error("wide division by zero")
    if _unsigned_cmp(value, divisor) < 0:
        return (_Wide(0, 0), value)
    if divisor.high == 0:
        var quotient, remainder = _wide_div128(value, divisor.low)
        return (quotient, _Wide(0, remainder))
    # D1: normalize into a three-word dividend and a two-word divisor.
    var shift = Int(count_leading_zeros(divisor.high))
    var v0 = divisor.low
    var v1 = divisor.high
    var u0 = value.low
    var u1 = value.high
    var u2 = UInt128(0)
    if shift > 0:
        v0 = divisor.low << UInt128(shift)
        v1 = (divisor.high << UInt128(shift)) | (divisor.low >> UInt128(128 - shift))
        u0 = value.low << UInt128(shift)
        u1 = (value.high << UInt128(shift)) | (value.low >> UInt128(128 - shift))
        u2 = value.high >> UInt128(128 - shift)
    # D3: estimate/correct the only possible quotient digit.
    var q = UInt128.MAX
    if u2 < v1:
        var r: UInt128
        q, r = _udiv256_128(u2, u1, v1)
        while True:
            var product = _umul128(q, v0)
            if product.high < r or (product.high == r and product.low <= u0):
                break
            q -= 1
            var previous = r
            r += v1
            if r < previous:
                break
    # D4: fullmul_u256_u128 and three-word subtraction with borrow.
    var lower = _umul128(v0, q)
    var upper = _umul128(v1, q)
    var p1 = lower.high + upper.low
    var p2 = upper.high + UInt128(p1 < lower.high)
    var carry = False
    u0, carry = _sub_carry(u0, lower.low, carry)
    u1, carry = _sub_carry(u1, p1, carry)
    u2, carry = _sub_carry(u2, p2, carry)
    # D6: retain the source's rare estimate-too-large correction.
    if carry:
        q -= 1
        carry = False
        u0, carry = _add_carry(u0, v0, carry)
        u1, carry = _add_carry(u1, v1, carry)
        u2 += UInt128(carry)
    # D8: denormalize the remainder without a shift by the word width.
    var remainder = _Wide(u1, u0)
    if shift > 0:
        remainder.low = (u0 >> UInt128(shift)) | (u1 << UInt128(128 - shift))
        remainder.high = (u1 >> UInt128(shift)) | (u2 << UInt128(128 - shift))
    return (_Wide(0, q), remainder)


def _decimal_integer(value: _Wide, scale: Int, width: Int, exact: Bool) raises -> Optional[_Wide]:
    # jsonb exact_decimal_i128/i256 and round_decimal_i128/i256.
    if scale == 0:
        return value
    if scale > (77 if width == 256 else 38):
        return _Wide(0, 0) if not exact or value.zero() else Optional[_Wide]()
    var divisor = _Wide(0, 10).pow(scale)
    var negative = value.negative()
    var magnitude = value.neg() if negative else value
    var quotient, remainder = _wide_divmod(magnitude, divisor)
    if exact:
        if not remainder.zero():
            return None
    elif _unsigned_cmp(remainder, _unsigned_sub(divisor, remainder)) >= 0:
        var low = quotient.low + 1
        var high = quotient.high + UInt128(low == 0)
        if high < quotient.high:
            return None
        quotient = _Wide(high, low)
    # Original signed_i256_from_abs checks magnitude before applying the sign.
    if quotient.negative():
        return None
    return quotient.neg() if negative else quotient


def _fits_i128(value: _Wide) -> Bool:
    return value.high == (UInt128.MAX if bitcast[DType.int128](value.low) < 0 else UInt128(0))


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

    def _integer(self, exact: Bool) raises -> Optional[_Wide]:
        if self.kind == 0 or self.kind == 1:
            return self.value
        if self.kind == 2:
            var value = self.as_f64()
            if not isfinite(value):
                return None
            if exact:
                if external_call["trunc", Float64](value) != value:
                    return None
            else:
                # Rust round() and libm round use ties away from zero.
                value = external_call["round", Float64](value)
            var lower = Float64(Int128.MIN)
            if value < lower or value >= -lower:
                return None
            return _Wide.signed(Int128(value))
        if self.kind >= 3 and self.kind <= 5:
            return _decimal_integer(self.value, Int(self.scale), 256 if self.kind == 5 else 128, exact)
        raise Error("invalid JSONB Number kind")

    def as_i64(self) raises -> Optional[Int64]:
        """Exact source i64 conversion; fractional values are absent."""
        var value = self._integer(True)
        if not value:
            return None
        var integer = bitcast[DType.int64](UInt64(value.value().low))
        var expected = _Wide.signed(Int128(integer))
        if value.value().high != expected.high or value.value().low != expected.low:
            return None
        return integer

    def as_u64(self) raises -> Optional[UInt64]:
        """Exact source u64 conversion, rejecting negative/fractional values."""
        var value = self._integer(True)
        if not value or value.value().high != 0 or value.value().low > UInt128(UInt64.MAX):
            return None
        return UInt64(value.value().low)

    def to_i128(self) raises -> Optional[Int128]:
        """Source rounding to nearest integer, ties away from zero."""
        var value = self._integer(False)
        if not value or not _fits_i128(value.value()):
            return None
        return bitcast[DType.int128](value.value().low)

    def to_i64(self) raises -> Optional[Int64]:
        var value = self.to_i128()
        if not value or value.value() < Int128(Int64.MIN) or value.value() > Int128(Int64.MAX):
            return None
        return Int64(value.value())

    def to_u64(self) raises -> Optional[UInt64]:
        var value = self.to_i128()
        if not value or value.value() < 0 or value.value() > Int128(UInt64.MAX):
            return None
        return UInt64(value.value())

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
