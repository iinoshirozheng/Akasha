"""F64 decimal parser ported from fast-float2 0.2.3, MIT.

Source units: number.rs, binary.rs, decimal.rs, simple.rs, parse.rs and the F64
constants in float.rs. Tables are copied from the checksum-verified crate.
Byte-index loops replace Rust slice cursors and eight-byte digit batching;
integer arithmetic, rounding, truncation and all three conversion paths remain.
This is the numeric dependency for jsonb, separate from serde_json's profile.
"""
from std.bit import count_leading_zeros
from std.memory import bitcast
from akasha.document.fast_float_tables import (
    powers_of_five, decimal_shift, decimal_pow5, int_pow10, float_pow10,
    binary_shifts,
)


def _digit(c: UInt8) -> Bool:
    return c >= 48 and c <= 57


@fieldwise_init
struct _Number(ImplicitlyCopyable):
    var exponent: Int
    var mantissa: UInt64
    var negative: Bool
    var many_digits: Bool
    var consumed: Int

    def fast_path(self) -> Optional[Float64]:
        if self.exponent < -22 or self.exponent > 37 or self.mantissa > (UInt64(2) << 52) or self.many_digits:
            return None
        var value: Float64
        var powers = float_pow10()
        if self.exponent <= 22:
            value = Float64(self.mantissa)
            if self.exponent < 0:
                value /= powers[-self.exponent]
            else:
                value *= powers[self.exponent]
        else:
            var integers = int_pow10()
            var factor = integers[self.exponent - 22]
            if self.mantissa > UInt64.MAX // factor:
                return None
            var mantissa = self.mantissa * factor
            if mantissa > (UInt64(2) << 52):
                return None
            value = Float64(mantissa) * powers[22]
        return -value if self.negative else value


def _scientific[origin: ImmOrigin](s: Span[UInt8, origin], mut pos: Int) -> Int:
    if pos == len(s) or (s[pos] != 101 and s[pos] != 69):
        return 0
    var start = pos
    pos += 1
    var negative = False
    if pos < len(s) and (s[pos] == 45 or s[pos] == 43):
        negative = s[pos] == 45
        pos += 1
    if pos == len(s) or not _digit(s[pos]):
        pos = start
        return 0
    var exponent = 0
    while pos < len(s) and _digit(s[pos]):
        if exponent < 0x10000:
            exponent = 10 * exponent + Int(s[pos]) - 48
        pos += 1
    return -exponent if negative else exponent


def _parse_number[origin: ImmOrigin](s: Span[UInt8, origin]) raises -> _Number:
    var pos = 0
    var negative = False
    if len(s) != 0 and (s[0] == 45 or s[0] == 43):
        negative = s[0] == 45
        pos += 1
    if pos == len(s):
        raise Error("error while parsing a float")
    var digits_start = pos
    var mantissa = UInt64(0)
    while pos < len(s) and _digit(s[pos]):
        mantissa = mantissa * 10 + UInt64(s[pos] - 48)
        pos += 1
    var digits = pos - digits_start
    var int_end = pos
    var exponent = 0
    if pos < len(s) and s[pos] == 46:
        pos += 1
        var before = pos
        while pos < len(s) and _digit(s[pos]):
            mantissa = mantissa * 10 + UInt64(s[pos] - 48)
            pos += 1
        exponent = before - pos
        digits += pos - before
    if digits == 0:
        raise Error("error while parsing a float")
    var scientific = _scientific(s, pos)
    exponent += scientific
    var consumed = pos
    var many_digits = False
    if digits > 19:
        digits -= 19
        pos = digits_start
        while pos < len(s) and (s[pos] == 48 or s[pos] == 46):
            if s[pos] == 48:
                digits -= 1
            pos += 1
        if digits > 0:
            many_digits = True
            mantissa = 0
            pos = digits_start
            while mantissa < 1000000000000000000 and pos < len(s) and _digit(s[pos]):
                mantissa = mantissa * 10 + UInt64(s[pos] - 48)
                pos += 1
            if mantissa >= 1000000000000000000:
                exponent = int_end - pos
            else:
                pos += 1  # Source proof: the integer digits end at a dot.
                var before = pos
                while mantissa < 1000000000000000000 and pos < len(s) and _digit(s[pos]):
                    mantissa = mantissa * 10 + UInt64(s[pos] - 48)
                    pos += 1
                exponent = before - pos
            exponent += scientific
    return _Number(exponent, mantissa, negative, many_digits, consumed)


@fieldwise_init
struct _AdjustedMantissa(ImplicitlyCopyable):
    var mantissa: UInt64
    var power2: Int

    def bits(self, negative: Bool) -> UInt64:
        var result = self.mantissa | (UInt64(self.power2) << 52)
        if negative:
            result |= UInt64(1) << 63
        return result


def _full_multiplication(a: UInt64, b: UInt64) -> Tuple[UInt64, UInt64]:
    var product = UInt128(a) * UInt128(b)
    return UInt64(product), UInt64(product >> 64)


def _compute_float(q: Int, var w: UInt64) -> _AdjustedMantissa:
    if w == 0 or q < -342:
        return _AdjustedMantissa(0, 0)
    if q > 308:
        return _AdjustedMantissa(0, 0x7ff)
    var lz = Int(count_leading_zeros(w))
    w <<= UInt64(lz)
    var powers = powers_of_five()
    var index = 2 * (q + 342)
    var lo: UInt64
    var hi: UInt64
    lo, hi = _full_multiplication(w, powers[index])
    var mask = UInt64.MAX >> 55
    if hi & mask == mask:
        var second = _full_multiplication(w, powers[index + 1])[1]
        lo += second
        if second > lo:
            hi += 1
    if lo == UInt64.MAX and (q < -27 or q > 55):
        return _AdjustedMantissa(0, -1)
    var upperbit = Int(hi >> 63)
    var mantissa = hi >> UInt64(upperbit + 9)
    var power2 = ((q * 217706) >> 16) + 63 + upperbit - lz + 1023
    if power2 <= 0:
        if -power2 + 1 >= 64:
            return _AdjustedMantissa(0, 0)
        mantissa >>= UInt64(-power2 + 1)
        mantissa += mantissa & 1
        mantissa >>= 1
        power2 = Int(mantissa >= (UInt64(1) << 52))
        return _AdjustedMantissa(mantissa, power2)
    if lo <= 1 and q >= -4 and q <= 23 and mantissa & 3 == 1 and (mantissa << UInt64(upperbit + 9)) == hi:
        mantissa &= ~UInt64(1)
    mantissa += mantissa & 1
    mantissa >>= 1
    if mantissa >= (UInt64(2) << 52):
        mantissa = UInt64(1) << 52
        power2 += 1
    mantissa &= ~(UInt64(1) << 52)
    if power2 >= 0x7ff:
        return _AdjustedMantissa(0, 0x7ff)
    return _AdjustedMantissa(mantissa, power2)


struct _Decimal(Movable):
    var num_digits: Int
    var decimal_point: Int
    var truncated: Bool
    var digits: Array[UInt8, 768]

    def __init__(out self):
        self.num_digits = 0
        self.decimal_point = 0
        self.truncated = False
        self.digits = Array[UInt8, 768](fill=0)

    def add(mut self, digit: UInt8):
        if self.num_digits < 768:
            self.digits[self.num_digits] = digit
        self.num_digits += 1

    def trim(mut self):
        while self.num_digits != 0 and self.digits[self.num_digits - 1] == 0:
            self.num_digits -= 1

    def round(self) -> UInt64:
        if self.num_digits == 0 or self.decimal_point < 0:
            return 0
        if self.decimal_point > 18:
            return UInt64.MAX
        var n = UInt64(0)
        var dp = self.decimal_point
        for i in range(dp):
            n *= 10
            if i < self.num_digits:
                n += UInt64(self.digits[i])
        var round_up = False
        if dp < self.num_digits:
            round_up = self.digits[dp] >= 5
            if self.digits[dp] == 5 and dp + 1 == self.num_digits:
                round_up = self.truncated or (dp != 0 and (self.digits[dp - 1] & 1) != 0)
        if round_up:
            n += 1
        return n

    def new_digits(self, var shift: Int) -> Int:
        var table = decimal_shift()
        var pow5 = decimal_pow5()
        shift &= 63
        var a = Int(table[shift])
        var b = Int(table[shift + 1])
        var added = a >> 11
        var start = a & 0x7ff
        var end = b & 0x7ff
        for i in range(end - start):
            if i >= self.num_digits or self.digits[i] < pow5[start + i]:
                return added - 1
            if self.digits[i] > pow5[start + i]:
                return added
        return added

    def left_shift(mut self, shift: Int):
        if self.num_digits == 0:
            return
        var added = self.new_digits(shift)
        var read_index = self.num_digits
        var write_index = self.num_digits + added
        var n = UInt64(0)
        while read_index != 0:
            read_index -= 1
            write_index -= 1
            n += UInt64(self.digits[read_index]) << UInt64(shift)
            var quotient = n // 10
            var remainder = n - 10 * quotient
            if write_index < 768:
                self.digits[write_index] = UInt8(remainder)
            elif remainder > 0:
                self.truncated = True
            n = quotient
        while n > 0:
            write_index -= 1
            var quotient = n // 10
            var remainder = n - 10 * quotient
            if write_index < 768:
                self.digits[write_index] = UInt8(remainder)
            elif remainder > 0:
                self.truncated = True
            n = quotient
        self.num_digits += added
        if self.num_digits > 768:
            self.num_digits = 768
        self.decimal_point += added
        self.trim()

    def right_shift(mut self, shift: Int):
        var read_index = 0
        var write_index = 0
        var n = UInt64(0)
        while (n >> UInt64(shift)) == 0:
            if read_index < self.num_digits:
                n = 10 * n + UInt64(self.digits[read_index])
                read_index += 1
            elif n == 0:
                return
            else:
                while (n >> UInt64(shift)) == 0:
                    n *= 10
                    read_index += 1
                break
        self.decimal_point -= read_index - 1
        if self.decimal_point < -2047:
            self.num_digits = 0
            self.decimal_point = 0
            self.truncated = False
            return
        var mask = (UInt64(1) << UInt64(shift)) - 1
        while read_index < self.num_digits:
            var digit = UInt8(n >> UInt64(shift))
            n = 10 * (n & mask) + UInt64(self.digits[read_index])
            read_index += 1
            self.digits[write_index] = digit
            write_index += 1
        while n > 0:
            var digit = UInt8(n >> UInt64(shift))
            n = 10 * (n & mask)
            if write_index < 768:
                self.digits[write_index] = digit
                write_index += 1
            elif digit > 0:
                self.truncated = True
        self.num_digits = write_index
        self.trim()


def _parse_decimal[origin: ImmOrigin](s: Span[UInt8, origin]) -> _Decimal:
    # Internal precondition, as upstream: parse_number already accepted s.
    var d = _Decimal()
    var pos = 0
    if s[0] == 45 or s[0] == 43:
        pos += 1
    while pos < len(s) and s[pos] == 48:
        pos += 1
    while pos < len(s) and _digit(s[pos]):
        d.add(s[pos] - 48)
        pos += 1
    if pos < len(s) and s[pos] == 46:
        pos += 1
        var first = pos
        if d.num_digits == 0:
            while pos < len(s) and s[pos] == 48:
                pos += 1
        while pos < len(s) and _digit(s[pos]):
            d.add(s[pos] - 48)
            pos += 1
        d.decimal_point = first - pos
    if d.num_digits != 0:
        var trailing = 0
        var end = pos
        while end != 0:
            end -= 1
            if s[end] == 48:
                trailing += 1
            elif s[end] != 46:
                break
        d.decimal_point += trailing
        d.num_digits -= trailing
        d.decimal_point += d.num_digits
        if d.num_digits > 768:
            d.truncated = True
            d.num_digits = 768
    d.decimal_point += _scientific(s, pos)
    for i in range(d.num_digits, 19):
        d.digits[i] = 0
    return d^


def _get_shift(n: Int) -> Int:
    var powers = binary_shifts()
    return powers[n] if n < 19 else 60


def _parse_long_mantissa[origin: ImmOrigin](s: Span[UInt8, origin]) -> _AdjustedMantissa:
    var d = _parse_decimal(s)
    if d.num_digits == 0 or d.decimal_point < -324:
        return _AdjustedMantissa(0, 0)
    if d.decimal_point >= 310:
        return _AdjustedMantissa(0, 0x7ff)
    var exp2 = 0
    while d.decimal_point > 0:
        var shift = _get_shift(d.decimal_point)
        d.right_shift(shift)
        if d.decimal_point < -2047:
            return _AdjustedMantissa(0, 0)
        exp2 += shift
    while d.decimal_point <= 0:
        var shift: Int
        if d.decimal_point == 0:
            if d.digits[0] >= 5:
                break
            shift = 2 if d.digits[0] <= 1 else 1
        else:
            shift = _get_shift(-d.decimal_point)
        d.left_shift(shift)
        if d.decimal_point > 2047:
            return _AdjustedMantissa(0, 0x7ff)
        exp2 -= shift
    exp2 -= 1
    while -1022 > exp2:
        var shift = -1022 - exp2
        if shift > 60:
            shift = 60
        d.right_shift(shift)
        exp2 += shift
    if exp2 + 1023 >= 0x7ff:
        return _AdjustedMantissa(0, 0x7ff)
    d.left_shift(53)
    var mantissa = d.round()
    if mantissa >= (UInt64(1) << 53):
        d.right_shift(1)
        exp2 += 1
        mantissa = d.round()
        if exp2 + 1023 >= 0x7ff:
            return _AdjustedMantissa(0, 0x7ff)
    var power2 = exp2 + 1023
    if mantissa < (UInt64(1) << 52):
        power2 -= 1
    mantissa &= (UInt64(1) << 52) - 1
    return _AdjustedMantissa(mantissa, power2)


def _prefix[origin: ImmOrigin](s: Span[UInt8, origin], start: Int, text: String) -> Bool:
    var expected = text.as_bytes()
    if len(s) - start < len(expected):
        return False
    var difference = UInt8(0)
    for i in range(len(expected)):
        difference |= s[start + i] ^ expected[i]
    return difference == 0 or difference == 32


def _inf_nan[origin: ImmOrigin](s: Span[UInt8, origin]) raises -> Tuple[Float64, Int]:
    var start = 0
    var negative = False
    if len(s) != 0 and (s[0] == 45 or s[0] == 43):
        negative = s[0] == 45
        start = 1
    var bits: UInt64
    var consumed = start + 3
    if _prefix(s, start, "nan"):
        bits = 0x7ff8000000000000
    elif _prefix(s, start, "inf"):
        bits = 0x7ff0000000000000
        if _prefix(s, start + 3, "inity"):
            consumed += 5
    else:
        raise Error("error while parsing a float")
    if negative:
        bits |= UInt64(1) << 63
    return bitcast[DType.float64](bits), consumed


def parse_fast_float_partial[origin: ImmOrigin](s: Span[UInt8, origin]) raises -> Tuple[Float64, Int]:
    """Parse an F64 prefix; return its value and consumed byte count."""
    var num: _Number
    try:
        num = _parse_number(s)
    except:
        return _inf_nan(s)
    var fast = num.fast_path()
    if fast:
        return fast.value(), num.consumed
    var am = _compute_float(num.exponent, num.mantissa)
    if num.many_digits:
        var next = _compute_float(num.exponent, num.mantissa + 1)
        if am.mantissa != next.mantissa or am.power2 != next.power2:
            am.power2 = -1
    if am.power2 < 0:
        am = _parse_long_mantissa(s)
    return bitcast[DType.float64](am.bits(num.negative)), num.consumed


def parse_fast_float[origin: ImmOrigin](s: Span[UInt8, origin]) raises -> Float64:
    """Parse a complete F64 decimal token, rejecting any unconsumed bytes."""
    var result = parse_fast_float_partial(s)
    if result[1] != len(s):
        raise Error("error while parsing a float")
    return result[0]
