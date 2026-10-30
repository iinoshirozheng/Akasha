"""F64 formatting port of zmij 1.0.21 (MIT), lib.rs and traits.rs.

Retains yy's fast conversion, Schubfach boundary fallback, the source portable
BCD digit writer, and fixed/scientific notation rules. UInt128 replaces Rust's
u128; bounded byte offsets replace raw pointers. Source portable exponent math
is used on every platform, with no SIMD/assembly specialization. Tables are
emitted by the unchanged upstream Rust const functions, not recomputed here.
"""
from std.bit import count_leading_zeros
from std.memory import bitcast
from akasha.document.zmij_tables import powers_of_ten, exponent_shifts


@fieldwise_init
struct _Decimal(ImplicitlyCopyable):
    var sig: UInt64
    var exp: Int


def _mul_high(x: UInt64, y: UInt64) -> UInt64:
    return UInt64((UInt128(x) * UInt128(y)) >> 64)


def _mul192_high(x_hi: UInt64, x_lo: UInt64, y: UInt64) -> Tuple[UInt64, UInt64]:
    var product = UInt128(x_hi) * UInt128(y)
    var low = UInt64(product) + _mul_high(x_lo, y)
    return UInt64(product >> 64) + UInt64(low < UInt64(product)), low


def _mul_odd(x_hi: UInt64, x_lo: UInt64, y: UInt64) -> UInt64:
    var product = _mul192_high(x_hi, x_lo, y)
    return product[0] | UInt64((product[1] >> 1) != 0)


def _decimal_exponent(binary_exp: Int, regular: Bool) -> Int:
    return (binary_exp * 315653 - Int(not regular) * 131072) >> 20


def _exponent_shift(binary_exp: Int, decimal_exp: Int) -> Int:
    return binary_exp + ((-decimal_exp * 217707) >> 16) + 1


def _to_decimal_schubfach(binary_sig: UInt64, binary_exp: Int, regular: Bool) -> _Decimal:
    var decimal_exp = _decimal_exponent(binary_exp, regular)
    var shift = UInt64(_exponent_shift(binary_exp, decimal_exp))
    var powers = powers_of_ten()
    var index = 2 * (-decimal_exp + 292)
    var high = powers[index]
    var low = powers[index + 1] + 1  # Source strict overestimate.
    var shifted = binary_sig << 2
    var lsb = binary_sig & 1
    var lower = _mul_odd(high, low, (shifted - (UInt64(regular) + 1)) << shift) + lsb
    var upper = _mul_odd(high, low, (shifted + 2) << shift) - lsb
    var shorter = (upper >> 2) // 10 * 10
    if shorter << 2 >= lower:
        return _Decimal(shorter, decimal_exp)
    var scaled = _mul_odd(high, low, shifted << shift)
    var below = scaled >> 2
    var above = below + 1
    var comparison = bitcast[DType.int64](scaled - ((below + above) << 1))
    var below_closer = comparison < 0 or (comparison == 0 and (below & 1) == 0)
    var below_in = (below << 2) >= lower
    return _Decimal(below if below_closer and below_in else above, decimal_exp)


def _to_decimal_fast(binary_sig: UInt64, raw_exp: Int, regular: Bool) -> _Decimal:
    var binary_exp = raw_exp - 1075
    while regular:
        var decimal_exp = _decimal_exponent(binary_exp, True)
        var shifts = exponent_shifts()
        var shift = UInt64(shifts[raw_exp])
        var powers = powers_of_ten()
        var index = 2 * (-decimal_exp + 292)
        var high = powers[index]
        var product = _mul192_high(high, powers[index + 1], binary_sig << shift)
        var integral = product[0]
        var fractional = product[1]
        var comparison = bitcast[DType.int64](fractional - (UInt64(1) << 63))
        if comparison == 0:
            break
        var div10 = _mul_high(integral, (UInt64(1) << 63) // 5 + 1)
        var digit = integral - div10 * 10
        var ten = UInt64(10) << 60
        var scaled_mod10 = (digit << 60) | (fractional >> 4)
        var half_ulp = high >> (5 - shift)
        var upper = scaled_mod10 + half_ulp
        if ten - upper <= 1 or scaled_mod10 == half_ulp:
            break
        var shorter = integral - digit
        var longer = integral + UInt64(comparison >= 0)
        var significand = shorter if scaled_mod10 < half_ulp else longer
        return _Decimal(shorter + 10 if ten < upper else significand, decimal_exp)
    return _to_decimal_schubfach(binary_sig, binary_exp, regular)


def _to_bcd8(value: UInt64) -> UInt64:
    var abcd_efgh = value + ((UInt64(1) << 32) - 10000) * ((value * ((UInt64(1) << 40) // 10000 + 1)) >> 40)
    var ab_cd_ef_gh = abcd_efgh + ((UInt64(1) << 16) - 100) * (((abcd_efgh * ((UInt64(1) << 19) // 100 + 1)) >> 19) & 0x7f0000007f)
    var packed = ab_cd_ef_gh + ((UInt64(1) << 8) - 10) * (((ab_cd_ef_gh * ((UInt64(1) << 10) // 10 + 1)) >> 10) & 0xf000f000f000f)
    # Normalize the source to_be()/unaligned-write pair to explicit little-endian
    # byte packing so the writer does not depend on host byte order.
    var reversed = UInt64(0)
    for i in range(8):
        reversed = (reversed << 8) | ((packed >> UInt64(8 * i)) & 255)
    return reversed


def _count_trailing_nonzeros(value: UInt64) -> Int:
    return (70 - Int(count_leading_zeros((value << 1) | 1))) // 8


def _write8(mut buffer: Array[UInt8, 24], position: Int, value: UInt64):
    for i in range(8):
        buffer[position + i] = UInt8(value >> UInt64(8 * i))


def _write_significand(mut buffer: Array[UInt8, 24], var position: Int, value: UInt64, extra_digit: Bool) -> Int:
    var head = value // 100000000
    var tail = value % 100000000
    buffer[position] = 48 + UInt8(head // 100000000)
    position += Int(extra_digit)
    var bcd = _to_bcd8(head % 100000000)
    _write8(buffer, position, bcd + 0x3030303030303030)
    if tail == 0:
        return position + _count_trailing_nonzeros(bcd)
    bcd = _to_bcd8(tail)
    _write8(buffer, position + 8, bcd + 0x3030303030303030)
    return position + 8 + _count_trailing_nonzeros(bcd)


def format_zmij_finite(value: Float64) raises -> String:
    """Source finite F64 formatting; rejects nonfinite input (undefined upstream)."""
    var bits = bitcast[DType.uint64](value)
    var binary_exp = Int((bits >> 52) & 2047)
    if binary_exp == 2047:
        raise Error("zmij finite formatter requires a finite value")
    var binary_sig = bits & ((UInt64(1) << 52) - 1)
    var negative = (bits >> 63) != 0
    var buffer = Array[UInt8, 24](fill=0)
    buffer[0] = 45
    var start = Int(negative)
    var decimal: _Decimal
    if binary_exp == 0:
        if binary_sig == 0:
            return "-0.0" if negative else "0.0"
        decimal = _to_decimal_schubfach(binary_sig, -1074, True)
        while decimal.sig < 10000000000000000:
            decimal.sig *= 10
            decimal.exp -= 1
    else:
        decimal = _to_decimal_fast(binary_sig | (UInt64(1) << 52), binary_exp, binary_sig != 0)
    var extra_digit = decimal.sig >= 10000000000000000
    var decimal_exp = decimal.exp + 15 + Int(extra_digit)
    var end = _write_significand(buffer, start + 1, decimal.sig, extra_digit)
    var length = end - (start + 1)
    if decimal_exp >= -5 and decimal_exp <= 15:
        if length - 1 <= decimal_exp:
            for i in range(length):
                buffer[start + i] = buffer[start + 1 + i]
            for i in range(length, decimal_exp + 3):
                buffer[start + i] = 48
            buffer[start + decimal_exp + 1] = 46
            end = start + decimal_exp + 3
        elif decimal_exp >= 0:
            for i in range(decimal_exp + 1):
                buffer[start + i] = buffer[start + 1 + i]
            buffer[start + decimal_exp + 1] = 46
            end = start + length + 1
        else:
            # Source ptr::copy is memmove: rightward overlap copies backwards.
            for i in range(length - 1, -1, -1):
                buffer[start + 1 - decimal_exp + i] = buffer[start + 1 + i]
            for i in range(1 - decimal_exp):
                buffer[start + i] = 48
            buffer[start + 1] = 46
            end = start + 1 - decimal_exp + length
        return String(from_utf8=Span(buffer)[:end])
    buffer[start] = buffer[start + 1]
    buffer[start + 1] = 46
    var position = start + length + Int(length > 1)
    var sign_position = position
    var exponent_negative = decimal_exp < 0
    position += 1
    if exponent_negative:
        decimal_exp = -decimal_exp
    position += Int(decimal_exp >= 10)
    var digit = (decimal_exp * ((1 << 19) // 100 + 1)) >> 19
    buffer[position] = 48 + UInt8(digit)
    position += Int(decimal_exp >= 100)
    # Source DIGITS2 literal, retaining its overlapping exponent-write rules.
    var digits = "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"
    var pair = 2 * (decimal_exp - digit * 100)
    buffer[position] = digits.as_bytes()[pair]
    buffer[position + 1] = digits.as_bytes()[pair + 1]
    buffer[sign_position] = 101
    buffer[sign_position + 1] = 45 if exponent_negative else 43
    return String(from_utf8=Span(buffer)[:position + 2])


def format_zmij(value: Float64) raises -> String:
    """Source format(): shortest F64 decimal, signed zero, NaN and infinities."""
    var bits = bitcast[DType.uint64](value)
    if ((bits >> 52) & 2047) == 2047:
        if bits & ((UInt64(1) << 52) - 1) != 0:
            return "NaN"
        return "-inf" if (bits >> 63) != 0 else "inf"
    return format_zmij_finite(value)
