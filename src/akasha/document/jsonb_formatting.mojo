"""jsonb 0.5.6 number/extension text conversion (Apache-2.0).

Ports Number::serialize without arbitrary_precision and ExtensionValue::Display.
The 256-bit cast follows ethnum 1.5.3 (MIT); civil conversion and year/offset
formatting follow jiff 0.2.28 shared/util/itime.rs and fmt printers (MIT).
Only their JSONB-reachable operations are exposed here, not a general time API.
"""
from akasha.query.control import QueryControl
from std.math import pow, isfinite
from std.memory import bitcast
from akasha.document.jsonb import _read_be
from akasha.document.zmij import format_zmij_finite


def _float_text(value: Float64) raises -> String:
    # serde_json::Serializer::serialize_f64, before Formatter::write_f64.
    return format_zmij_finite(value) if isfinite(value) else "null"


def _read128(bytes: Span[UInt8, _], offset: Int) -> UInt128:
    var result = UInt128(0)
    for i in range(16):
        result = (result << 8) | UInt128(bytes[offset + i])
    return result


def _decimal_float(body: Span[UInt8, _]) raises -> Float64:
    var width = len(body) - 2
    if width == 17 or width == 33:
        width -= 1  # Old precision-bearing databend decimals.
    var value: Float64
    if width == 8:
        value = Float64(bitcast[DType.int64](_read_be(body, 1, 8)))
    elif width == 16:
        value = Float64(bitcast[DType.int128](_read128(body, 1)))
    else:
        var high = _read128(body, 1)
        var low = _read128(body, 17)
        var negative = (high >> 127) != 0
        if negative:
            low = UInt128(0) - low
            high = ~high + UInt128(low == 0)
        # ethnum::I256::as_f64 -> unsigned_abs().as_f64() * signum128().
        # Retain its two independent UInt128 casts and rounded addition.
        value = Float64(high) * bitcast[DType.float64](UInt64(0x47f0000000000000)) + Float64(low)
        if negative:
            value = -value
    return value / pow(Float64(10), Int(body[len(body) - 1]))


def format_jsonb_number(body: Span[UInt8, _]) raises -> String:
    var kind = body[0]
    if kind == 0:
        return "0"
    if kind == 0x10 or kind == 0x20 or kind == 0x30:
        return "null"
    if kind == 0x60:
        return _float_text(bitcast[DType.float64](_read_be(body, 1, 8)))
    if kind == 0x70:
        return _float_text(_decimal_float(body))
    var width = len(body) - 1
    var integer = _read_be(body, 1, width)
    if kind == 0x40:
        if width < 8 and body[1] & UInt8(0x80):
            integer |= UInt64.MAX << UInt64(width * 8)
        return String(bitcast[DType.int64](integer))
    return String(integer)


def _civil_date(epoch_day: Int) raises -> Tuple[Int, Int, Int]:
    # jiff IEpochDay::to_date: Neri-Schneider, with source range validation.
    if epoch_day < -4371587 or epoch_day > 2932896:
        raise Error("JSONB date exceeds source calendar range")
    var n = UInt32(epoch_day) + UInt32(719468 + 146097 * 82)
    var n1 = 4 * n + 3
    var century = n1 // 146097
    var nc = (n1 % 146097) // 4
    var n2 = 4 * nc + 3
    var p2 = UInt64(2939745) * UInt64(n2)
    var z = UInt32(p2 // 4294967296)
    var ny = UInt32(p2 % 4294967296) // 2939745 // 4
    var year = 100 * century + z
    var n3 = 2141 * ny + 197913
    var month = n3 // 65536
    var day = (n3 % 65536) // 2141
    var jan_feb = ny >= 306
    return Int(year) - 400 * 82 + Int(jan_feb), Int(month) - (12 if jan_feb else 0), Int(day) + 1


def _pad(value: Int, width: Int) -> String:
    # Source integer printers include the minus sign in the minimum width.
    var negative = value < 0
    var magnitude = UInt64(-Int128(value) if negative else Int128(value))
    var digits = String(magnitude)
    var result = String("-") if negative else String()
    for _ in range(max(0, width - Int(negative) - digits.byte_length())):
        result += "0"
    return result + digits


def _date_text(days: Int) raises -> String:
    var date = _civil_date(days)
    var year = date[0]
    # jiff Temporal date Display uses six magnitude digits for BCE, whereas
    # strtime's %Y (used by timestamps below) has minimum total width four.
    var text = "-00" + _pad(-year, 4) if year < 0 else _pad(year, 4)
    return text + "-" + _pad(date[1], 2) + "-" + _pad(date[2], 2)


def _div_zero(value: Int, divisor: Int) -> Int:
    # Rust signed division truncates toward zero; Mojo // floors.
    return -Int((-Int128(value)) // Int128(divisor)) if value < 0 else value // divisor


def _timestamp_text(micros: Int, offset: Int, zoned: Bool) raises -> String:
    var seconds = _div_zero(micros, 1000000)
    var fraction = micros - seconds * 1000000
    if fraction < 0:
        seconds -= 1
        fraction += 1000000
    if seconds > 253402207200:
        seconds = 253402207200
        fraction = 0
    elif seconds < -377705023201:
        seconds = -377705023201
        fraction = 0
    if offset < -93599 or offset > 93599:
        raise Error("invalid JSONB timezone offset seconds")
    # jiff ITimestamp::to_datetime positive-domain shift. jsonb already
    # normalized the fraction; jiff's intervening signed-duration conversion
    # and negative-nanosecond adjustment cancel each other here.
    var day_shift = 30 * 146097
    var positive_seconds = seconds + offset + day_shift * 86400
    var date = _civil_date(positive_seconds // 86400 - day_shift)
    var day_seconds = positive_seconds % 86400
    var hour = day_seconds // 3600
    var minute = (day_seconds % 3600) // 60
    var second = day_seconds % 60
    var text = _pad(date[0], 4) + "-" + _pad(date[1], 2) + "-" + _pad(date[2], 2)
    text += " " + _pad(hour, 2) + ":" + _pad(minute, 2) + ":" + _pad(second, 2) + "." + _pad(fraction, 6)
    if zoned:
        var magnitude = -offset if offset < 0 else offset
        text += " -" if offset < 0 else " +"
        text += _pad(magnitude // 3600, 2) + _pad((magnitude // 60) % 60, 2)
        if magnitude % 60 != 0:
            text += _pad(magnitude % 60, 2)
    return text


def _interval_component(mut text: String, value: Int, singular: String, plural: String):
    if value == 0:
        return
    if text.byte_length() != 0:
        text += " "
    # Keep the pinned release source's wrapping i32::abs at MIN, including
    # its double minus sign. This is existing wire behavior, not normalized.
    var absolute = value
    if value < 0:
        absolute = Int(bitcast[DType.int32](UInt32(0) - bitcast[DType.uint32](Int32(value))))
        text += "-"
    text += String(absolute) + " " + (singular if absolute == 1 else plural)


def _interval_text(months: Int, days: Int, var micros: Int) -> String:
    var text = String()
    var years = _div_zero(months, 12)
    _interval_component(text, years, "year", "years")
    _interval_component(text, months - years * 12, "month", "months")
    _interval_component(text, days, "day", "days")
    if micros != 0:
        if text.byte_length() != 0:
            text += " "
        if micros < 0:
            text += "-"
            micros = Int(bitcast[DType.int64](UInt64(0) - bitcast[DType.uint64](Int64(micros))))
        var hour = _div_zero(micros, 3600000000)
        micros -= hour * 3600000000
        var minute = _div_zero(micros, 60000000)
        micros -= minute * 60000000
        var second = _div_zero(micros, 1000000)
        micros -= second * 1000000
        text += _pad(hour, 2) + ":" + _pad(minute, 2) + ":" + _pad(second, 2)
        if micros != 0:
            text += "." + _pad(micros, 6)
    elif text.byte_length() == 0:
        text = "00:00:00"
    return text


def format_jsonb_extension(body: Span[UInt8, _], control: Optional[QueryControl] = None) raises -> String:
    var kind = body[0]
    if kind == 0:
        var result = List[UInt8](capacity=(len(body) - 1) * 2)
        var hex = "0123456789ABCDEF"
        for i in range(1, len(body)):
            if control:
                control.value().checkpoint(i - 1)
            result.append(hex.as_bytes()[Int(body[i] >> 4)])
            result.append(hex.as_bytes()[Int(body[i] & 15)])
        return String(from_utf8=Span(result))
    if kind == 0x10:
        return _date_text(Int(bitcast[DType.int32](UInt32(_read_be(body, 1, 4)))))
    if kind == 0x20 or kind == 0x30:
        var micros = Int(bitcast[DType.int64](_read_be(body, 1, 8)))
        var offset = 0
        if kind == 0x30:
            offset = Int(bitcast[DType.int8](body[9])) * 3600 if len(body) == 10 else Int(bitcast[DType.int32](UInt32(_read_be(body, 9, 4))))
        return _timestamp_text(micros, offset, kind == 0x30)
    return _interval_text(Int(bitcast[DType.int32](UInt32(_read_be(body, 1, 4)))),
                          Int(bitcast[DType.int32](UInt32(_read_be(body, 5, 4)))),
                          Int(bitcast[DType.int64](_read_be(body, 9, 8))))
