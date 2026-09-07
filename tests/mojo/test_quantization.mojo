from akasha.compute.quantization import (
    decode_bf16,
    decode_f16,
    decode_symmetric_i8,
    encode_bf16,
    encode_f16,
    encode_symmetric_i8,
    i8_dot_f32,
    normalize_for_cosine_i8,
    round_clamp_u8,
    symmetric_i8_scale,
)
from akasha.index.quantization import Sq8Codebook, Sq8Index
from std.math import abs, inf, isfinite
from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from std.utils.numerics import nextafter


def test_native_bf16_conversion_is_deterministic_and_rounds_to_even() raises:
    assert_equal(encode_bf16(Float32(0.0)), UInt16(0x0000))
    assert_equal(encode_bf16(Float32(-0.0)), UInt16(0x8000))
    assert_equal(encode_bf16(Float32(1.0)), UInt16(0x3F80))
    assert_equal(encode_bf16(Float32(-2.5)), UInt16(0xC020))
    assert_equal(encode_bf16(Float32(1.00390625)), UInt16(0x3F80))
    assert_equal(encode_bf16(Float32(1.0039064)), UInt16(0x3F81))
    assert_equal(decode_bf16(UInt16(0x7F7F)), Float32(3.38953139e38))
    assert_equal(encode_bf16(Float32(1.5)), encode_bf16(Float32(1.5)))


def test_native_f16_conversion_is_deterministic_and_rounds_to_even() raises:
    assert_equal(encode_f16(Float32(0.0)), UInt16(0x0000))
    assert_equal(encode_f16(Float32(-0.0)), UInt16(0x8000))
    assert_equal(encode_f16(Float32(1.0)), UInt16(0x3C00))
    assert_equal(encode_f16(Float32(-2.5)), UInt16(0xC100))
    assert_equal(encode_f16(Float32(1.00048828125)), UInt16(0x3C00))
    assert_equal(encode_f16(Float32(1.0004884)), UInt16(0x3C01))
    assert_equal(decode_f16(UInt16(0x7BFF)), Float32(65504.0))
    assert_equal(encode_f16(Float32(1.5)), encode_f16(Float32(1.5)))


def test_symmetric_i8_uses_per_vector_scale_rounding_and_saturation() raises:
    var values: List[Float32] = [-254.0, -1.0, 0.0, 1.0, 127.0]
    var scale = symmetric_i8_scale(values)
    assert_equal(scale, Float32(2.0))
    assert_equal(encode_symmetric_i8(Float32(-999.0), scale), Int8(-127))
    assert_equal(encode_symmetric_i8(Float32(-1.0), scale), Int8(-1))
    assert_equal(encode_symmetric_i8(Float32(127.0), scale), Int8(64))
    assert_equal(encode_symmetric_i8(Float32(999.0), scale), Int8(127))
    assert_equal(decode_symmetric_i8(Int8(64), scale), Float32(128.0))
    assert_equal(symmetric_i8_scale([0.0, -0.0]), Float32(0.0))
    assert_equal(encode_symmetric_i8(Float32(0.0), Float32(0.0)), Int8(0))


def test_shared_unsigned_rounding_matches_sq8_domain() raises:
    assert_equal(round_clamp_u8(Float32(-1.0)), UInt8(0))
    assert_equal(round_clamp_u8(Float32(0.49)), UInt8(0))
    assert_equal(round_clamp_u8(Float32(0.5)), UInt8(1))
    assert_equal(round_clamp_u8(Float32(254.5)), UInt8(255))
    assert_equal(round_clamp_u8(Float32(999.0)), UInt8(255))


def test_i8_dot_accumulates_in_integer_then_restores_magnitudes() raises:
    var lhs: List[Int8] = [Int8(127), Int8(-64), Int8(1)]
    var rhs: List[Int8] = [Int8(64), Int8(127), Int8(-2)]
    var expected_integer = Int32(127 * 64 - 64 * 127 - 2)
    assert_equal(i8_dot_f32(lhs, 2.0, rhs, 0.5), Float32(expected_integer))


def test_i8_checked_dot_rejects_unsafe_decoded_component_magnitude() raises:
    var codes: List[Int8] = [Int8(127)]
    with assert_raises():
        _ = i8_dot_f32(
            codes.copy(), Float32.MAX_FINITE, codes^, Float32(1.0)
        )


def test_i8_dot_scale_preserves_positive_and_negative_subnormals() raises:
    var smallest = nextafter(Float32(0.0), Float32(1.0))
    assert_true(smallest > 0.0)
    var positive_scale = symmetric_i8_scale([smallest])
    assert_equal(positive_scale, smallest)
    assert_equal(encode_symmetric_i8(smallest, positive_scale), Int8(1))
    assert_equal(encode_symmetric_i8(-smallest, positive_scale), Int8(-1))

    var three_smallest = smallest + smallest + smallest
    var mixed_scale = symmetric_i8_scale([smallest, -three_smallest])
    assert_equal(mixed_scale, three_smallest)
    assert_equal(encode_symmetric_i8(smallest, mixed_scale), Int8(0))
    assert_equal(
        encode_symmetric_i8(-three_smallest, mixed_scale), Int8(-1)
    )
    assert_true(isfinite(decode_symmetric_i8(Int8(-1), mixed_scale)))


def test_cosine_i8_normalizes_once_and_rejects_zero_norm() raises:
    var normalized = normalize_for_cosine_i8([3.0, 4.0])
    assert_true(abs(normalized[0] - 0.6) < 1.0e-6)
    assert_true(abs(normalized[1] - 0.8) < 1.0e-6)
    with assert_raises():
        _ = normalize_for_cosine_i8([0.0, 0.0])


def test_sq8_codebook_is_deterministic_and_bounds_reconstruction() raises:
    var vectors = List[List[Float32]]()
    vectors.append([0.0, 5.0, -2.0])
    vectors.append([10.0, 5.0, 2.0])
    vectors.append([4.0, 5.0, 0.5])

    var lhs = Sq8Codebook.train(vectors)
    var rhs = Sq8Codebook.train(vectors)
    assert_equal(lhs.version(), UInt32(1))
    assert_equal(lhs.dimension(), 3)
    assert_equal(lhs.minimum(0), rhs.minimum(0))
    assert_equal(lhs.scale(2), rhs.scale(2))

    var code = lhs.encode([4.0, 5.0, 0.5])
    var decoded = lhs.decode(code)
    assert_equal(code[1], UInt8(0))
    assert_equal(decoded[1], Float32(5.0))
    assert_true(abs(decoded[0] - 4.0) <= lhs.scale(0))
    assert_true(abs(decoded[2] - 0.5) <= lhs.scale(2))


def test_sq8_index_searches_all_metrics_with_stable_ties() raises:
    var ids: List[Int] = [1, 2, 3, 4]
    var vectors = List[List[Float32]]()
    vectors.append([1.0, 0.0])
    vectors.append([2.0, 0.0])
    vectors.append([2.0, 0.0])
    vectors.append([0.0, 1.0])
    var index = Sq8Index.build(ids, vectors)

    var dot = index.search_dot([1.0, 0.0], 3)
    var l2 = index.search_l2([1.8, 0.0], 2)
    var cosine = index.search_cosine([1.0, 0.0], 3)
    assert_equal(dot[0].id, 2)
    assert_equal(dot[1].id, 3)
    assert_equal(l2[0].id, 2)
    assert_equal(l2[1].id, 3)
    assert_equal(cosine[0].id, 1)
    assert_equal(cosine[1].id, 2)
    assert_equal(cosine[2].id, 3)
    assert_equal(index.encoded_bytes(), 8)
    assert_true(index.estimated_bytes() < len(vectors) * 2 * 4 + 64)


def test_sq8_rejects_invalid_training_and_queries() raises:
    with assert_raises():
        _ = Sq8Codebook.train(List[List[Float32]]())

    var malformed = List[List[Float32]]()
    malformed.append([1.0, 2.0])
    malformed.append([1.0])
    with assert_raises():
        _ = Sq8Codebook.train(malformed)

    var non_finite = List[List[Float32]]()
    non_finite.append([inf[DType.float32]()])
    with assert_raises():
        _ = Sq8Codebook.train(non_finite)

    var ids: List[Int] = [1]
    var vectors = List[List[Float32]]()
    vectors.append([1.0, 2.0])
    var index = Sq8Index.build(ids, vectors)
    with assert_raises():
        _ = index.search_dot([1.0], 1)
    with assert_raises():
        _ = index.search_l2([1.0, 2.0], 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
