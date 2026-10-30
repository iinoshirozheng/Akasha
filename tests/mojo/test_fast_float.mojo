from akasha.document.fast_float import (
    parse_fast_float, parse_fast_float_partial, _parse_number,
    _parse_long_mantissa, _compute_float, _full_multiplication,
)
from akasha.document.json_reader import parse_json
from std.memory import bitcast
from std.python import Python
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def test_pinned_source_f64_full_partial_and_long_paths() raises:
    var json = Python.import_module("json")
    var pathlib = Python.import_module("pathlib")
    var builtins = Python.import_module("builtins")
    var cases = json.loads(pathlib.Path("tests/fixtures/fast-float/cases.json").read_text())
    var counts = Dict[String, Int]()
    for row in cases:
        var bytes = List[UInt8]()
        for b in builtins.bytes.fromhex(row["hex"]):
            bytes.append(UInt8(Int(py=b)))
        try:
            var full = String(py=row["full"])
            if full == "-":
                with assert_raises():
                    _ = parse_fast_float(Span(bytes))
            else:
                assert_equal(String(bitcast[DType.uint64](parse_fast_float(Span(bytes)))), full)
            var partial = String(py=row["partial"])
            if partial == "-":
                with assert_raises():
                    _ = parse_fast_float_partial(Span(bytes))
            else:
                var result = parse_fast_float_partial(Span(bytes))
                assert_equal(String(bitcast[DType.uint64](result[0])), partial)
                assert_equal(result[1], Int(py=row["consumed"]))
            var expected_path = String(py=row["path"])
            var path = expected_path
            var forced = String(py=row["long"])
            if forced != "-":
                var number = _parse_number(Span(bytes))
                var am = _parse_long_mantissa(Span(bytes))
                assert_equal(String(am.bits(number.negative)), forced)
                if number.fast_path():
                    path = "disguised" if number.exponent > 22 else "fast"
                else:
                    var binary = _compute_float(number.exponent, number.mantissa)
                    var next = _compute_float(number.exponent, number.mantissa + 1)
                    path = "long" if binary.power2 < 0 or (number.many_digits and (binary.mantissa != next.mantissa or binary.power2 != next.power2)) else "binary"
                assert_equal(path, expected_path)
            counts[path] = counts.get(path, 0) + 1
        except err:
            print("fast-float source mismatch", row)
            raise err
    assert_equal(counts["invalid"], 2922)
    assert_equal(counts["special"], 107)
    assert_equal(counts["fast"], 1147)
    assert_equal(counts["disguised"], 36)
    assert_equal(counts["binary"], 10178)
    assert_equal(counts["long"], 801)


def test_negative_zero_overflow_underflow_and_ties() raises:
    var values: List[String] = [
        "-0", "-0.0", "-1e-99999", "1e99999", "-1e99999",
        "2.4703282292062327e-324", "2.4703282292062328e-324",
        "1.00000000000000011102230246251565404236316680908203125",
        "1.00000000000000011102230246251565404236316680908203126",
        "1.00000000000000033306690738754696212708950042724609375",
    ]
    var bits: List[UInt64] = [
        0x8000000000000000, 0x8000000000000000, 0x8000000000000000,
        0x7ff0000000000000, 0xfff0000000000000, 0, 1,
        0x3ff0000000000000, 0x3ff0000000000001, 0x3ff0000000000002,
    ]
    for i in range(len(values)):
        assert_equal(bitcast[DType.uint64](parse_fast_float(values[i].as_bytes())), bits[i])


def test_prefix_and_full_grammar_are_distinct() raises:
    for text in List[String](["1e", "1e+", "1e-", "1xyz"]):
        var result = parse_fast_float_partial(text.as_bytes())
        assert_equal(result[0], Float64(1))
        assert_equal(result[1], 1)
        with assert_raises():
            _ = parse_fast_float(text.as_bytes())
    for text in List[String]([" .5", ".", "+", "-", "++1", "--1", "e1"]):
        with assert_raises():
            _ = parse_fast_float_partial(text.as_bytes())
    assert_equal(parse_fast_float("+.5".as_bytes()), Float64(0.5))
    assert_equal(parse_fast_float("1.".as_bytes()), Float64(1))
    assert_equal(bitcast[DType.uint64](parse_fast_float("-NaN".as_bytes())), UInt64(0xfff8000000000000))


def test_source_full_width_multiplication() raises:
    for a in range(64):
        for b in range(64):
            var product = _full_multiplication(UInt64(1) << UInt64(a), UInt64(1) << UInt64(b))
            assert_equal(product[0], (UInt64(1) << UInt64(a + b)) if a + b < 64 else UInt64(0))
            assert_equal(product[1], (UInt64(1) << UInt64(a + b - 64)) if a + b >= 64 else UInt64(0))
    var product = _full_multiplication(UInt64.MAX, UInt64.MAX)
    assert_equal(product[0], UInt64(1))
    assert_equal(product[1], UInt64.MAX - 1)


def test_serde_json_numeric_profile_remains_distinct() raises:
    # Both constants are independently emitted by the two pinned source crates.
    var text = "18446744073709551615000e-308"
    assert_equal(bitcast[DType.uint64](parse_fast_float(text.as_bytes())), UInt64(332165511190492533))
    assert_equal(bitcast[DType.uint64](parse_json(text).as_float()), UInt64(332165511190492534))
    with assert_raises():
        _ = parse_json("1e99999")
    assert_equal(bitcast[DType.uint64](parse_fast_float("1e99999".as_bytes())), UInt64(0x7ff0000000000000))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
