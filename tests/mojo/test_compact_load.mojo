from akasha.compute.quantization import decode_bf16, decode_f16
from akasha.index.hnsw_storage import _load_compact_float, _load_compact_i8
from std.testing import assert_equal, assert_raises, TestSuite


def _exhaustive[scalar: DType]() raises:
    var bytes = List[UInt8](length=8, fill=0)
    for first in range(0, 65536, 4):
        var invalid = False
        for lane in range(4):
            var bits = UInt16(first + lane)
            bytes[lane * 2] = UInt8(bits)
            bytes[lane * 2 + 1] = UInt8(bits >> 8)
            comptime if scalar == DType.float16:
                invalid = invalid or (bits & 0x7C00) == 0x7C00
            else:
                invalid = invalid or (bits & 0x7F80) == 0x7F80
        if invalid:
            with assert_raises():
                _ = _load_compact_float[scalar, 4](bytes, 0)
        else:
            var actual = _load_compact_float[scalar, 4](bytes, 0)
            for lane in range(4):
                var expected: Float32
                comptime if scalar == DType.float16:
                    expected = decode_f16(UInt16(first + lane))
                else:
                    expected = decode_bf16(UInt16(first + lane))
                assert_equal(actual[lane], expected)
    with assert_raises():
        _ = _load_compact_float[scalar, 4](bytes, 2)
    with assert_raises():
        _ = _load_compact_float[scalar, 4](bytes, -2)


def test_packed_floats_exhaust_all_encodings_and_bounds() raises:
    _exhaustive[DType.float16]()
    _exhaustive[DType.bfloat16]()


def test_packed_i8_sign_extension_and_bounds() raises:
    var bytes = List[UInt8]()
    for value in range(256):
        bytes.append(UInt8(value))
    for offset in range(0, 256, 4):
        var values = _load_compact_i8[4](bytes, offset)
        for lane in range(4):
            var code = offset + lane
            assert_equal(
                values[lane], Int32(code if code < 128 else code - 256)
            )
    with assert_raises():
        _ = _load_compact_i8[4](bytes, 254)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
