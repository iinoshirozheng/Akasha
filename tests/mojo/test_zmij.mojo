from akasha.document.zmij import (
    format_zmij, format_zmij_finite, _to_decimal_fast, _to_decimal_schubfach,
    _to_bcd8, _count_trailing_nonzeros, _mul192_high, _decimal_exponent,
    _exponent_shift,
)
from akasha.document.zmij_tables import exponent_shifts
from akasha.document.fast_float import parse_fast_float
from std.memory import bitcast
from std.python import Python
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def test_pinned_source_format_and_both_decimal_paths() raises:
    var json = Python.import_module("json")
    var pathlib = Python.import_module("pathlib")
    var cases = json.loads(pathlib.Path("tests/fixtures/zmij/cases.json").read_text())
    var counts = Dict[String, Int]()
    for row in cases:
        var bits = UInt64(0)
        var bit_string = String(py=row["bits"])
        for digit in bit_string.as_bytes():
            bits = bits * 10 + UInt64(digit - 48)
        var value = bitcast[DType.float64](bits)
        var raw_exp = Int((bits >> 52) & 2047)
        var fraction = bits & ((UInt64(1) << 52) - 1)
        try:
            var text = format_zmij(value)
            assert_equal(text, String(py=row["text"]))
            assert_true(len(text.as_bytes()) <= 24)
            var kind: String
            if raw_exp == 2047:
                kind = "special"
                with assert_raises():
                    _ = format_zmij_finite(value)
            else:
                assert_equal(format_zmij_finite(value), text)
                assert_equal(bitcast[DType.uint64](parse_fast_float(text.as_bytes())), bits)
                if raw_exp == 0 and fraction == 0:
                    kind = "zero"
                else:
                    kind = "subnormal" if raw_exp == 0 else "irregular" if fraction == 0 else "regular"
                    var sig = fraction if raw_exp == 0 else fraction | (UInt64(1) << 52)
                    var regular = raw_exp == 0 or fraction != 0
                    var slow = _to_decimal_schubfach(sig, -1074 if raw_exp == 0 else raw_exp - 1075, regular)
                    var fast = slow if raw_exp == 0 else _to_decimal_fast(sig, raw_exp, regular)
                    assert_equal(String(fast.sig), String(py=row["sig"]))
                    assert_equal(fast.exp, Int(py=row["exp"]))
                    assert_equal(String(slow.sig), String(py=row["slow_sig"]))
                    assert_equal(slow.exp, Int(py=row["slow_exp"]))
            counts[kind] = counts.get(kind, 0) + 1
        except err:
            print("zmij source mismatch", row)
            raise err
    var expected = json.loads(pathlib.Path("tests/fixtures/zmij/sources.json").read_text())["counts"]
    for entry in counts.items():
        assert_equal(entry.value, Int(py=expected[entry.key]))
    assert_equal(counts["zero"], 2)
    assert_equal(counts["irregular"], 4092)


def test_source_notation_cutoffs_and_special_values() raises:
    var inputs: List[String] = [
        "0", "-0", "1", "1e-5", "1e-6", "1e15", "1e16", "1e99",
        "1e100", "1e-99", "1e-100", "5e-324", "-5e-324",
        "1.7976931348623157e308", "-1.7976931348623157e308",
        "5.444310685350916e14", "5.0507837461e-27", "5.0507837461000010e-27",
    ]
    var expected: List[String] = [
        "0.0", "-0.0", "1.0", "0.00001", "1e-6", "1000000000000000.0",
        "1e+16", "1e+99", "1e+100", "1e-99", "1e-100", "5e-324", "-5e-324",
        "1.7976931348623157e+308", "-1.7976931348623157e+308",
        "544431068535091.6", "5.0507837461e-27", "5.050783746100001e-27",
    ]
    for i in range(len(inputs)):
        assert_equal(format_zmij(parse_fast_float(inputs[i].as_bytes())), expected[i])
    var nan_bits: List[UInt64] = [0x7ff0000000000001, 0xfff0000000000001, 0x7ff8000000000000, 0xffffffffffffffff]
    for bits in nan_bits:
        assert_equal(format_zmij(bitcast[DType.float64](bits)), "NaN")
    assert_equal(format_zmij(bitcast[DType.float64](UInt64(0x7ff0000000000000))), "inf")
    assert_equal(format_zmij(bitcast[DType.float64](UInt64(0xfff0000000000000))), "-inf")


def test_source_portable_digit_packing_and_zero_trimming() raises:
    # BCD stages are checked independently from final formatting, especially
    # zero groups and decimal carry boundaries in the two eight-byte halves.
    var values: List[UInt64] = [0, 1, 9, 10, 99, 100, 9999, 10000, 10000000, 99999999, 12345678, 10101010]
    for value in values:
        var bcd = _to_bcd8(value)
        var reconstructed = UInt64(0)
        var length = 0
        for i in range(8):
            var digit = (bcd >> UInt64(8 * i)) & 255
            assert_true(digit <= 9)
            reconstructed = reconstructed * 10 + digit
            if digit != 0:
                length = i + 1
        assert_equal(reconstructed, value)
        assert_equal(_count_trailing_nonzeros(bcd), length)


def test_source_exponent_tables_and_full_width_carry() raises:
    var shifts = exponent_shifts()
    for raw_exp in range(2048):
        var binary_exp = -1074 if raw_exp == 0 else raw_exp - 1075
        assert_equal(Int(shifts[raw_exp]), _exponent_shift(binary_exp, _decimal_exponent(binary_exp, True)))
    var product = _mul192_high(UInt64.MAX, UInt64.MAX, UInt64.MAX)
    assert_equal(product[0], UInt64.MAX - 1)
    assert_equal(product[1], UInt64.MAX)
    product = _mul192_high(0, UInt64.MAX, UInt64.MAX)
    assert_equal(product[0], UInt64(0))
    assert_equal(product[1], UInt64.MAX - 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
