from akasha.common.config import I8_MAX_SAFE_DIMENSION
from std.math import abs, isfinite, sqrt
from std.memory import bitcast


comptime I8_SYMMETRIC_MAX = Int32(127)
def round_clamp_u8(value: Float32) raises -> UInt8:
    """Round a finite non-negative quantizer coordinate into one byte."""
    if not isfinite(value):
        raise Error("quantizer coordinates must be finite")
    if value <= 0.0:
        return UInt8(0)
    if value >= 254.5:
        return UInt8(255)
    return UInt8(Int(value + 0.5))


def encode_bf16(value: Float32) raises -> UInt16:
    """Encode one finite Float32 with Mojo's native BF16 conversion."""
    if not isfinite(value):
        raise Error("BF16 graph scalars must be finite")
    return bitcast[DType.uint16](BFloat16(value))


def decode_bf16(bits: UInt16) raises -> Float32:
    var value = Float32(bitcast[DType.bfloat16](bits))
    if not isfinite(value):
        raise Error("BF16 graph scalars must be finite")
    return value


def encode_f16(value: Float32) raises -> UInt16:
    """Encode one finite in-range Float32 as IEEE binary16."""
    if not isfinite(value):
        raise Error("F16 graph scalars must be finite")
    var compact = Float16(value)
    var decoded = Float32(compact)
    if not isfinite(decoded):
        raise Error("F16 graph scalar exceeds the finite range")
    return bitcast[DType.uint16](compact)


def decode_f16(bits: UInt16) raises -> Float32:
    var value = Float32(bitcast[DType.float16](bits))
    if not isfinite(value):
        raise Error("F16 graph scalars must be finite")
    return value


def symmetric_i8_scale(values: List[Float32]) raises -> Float32:
    """Return one magnitude-preserving symmetric scale for a vector."""
    if len(values) == 0:
        raise Error("I8 graph vectors must be non-empty")
    var maximum = Float32(0.0)
    for value in values:
        if not isfinite(value):
            raise Error("I8 graph vectors must be finite")
        var magnitude = abs(value)
        if magnitude > maximum:
            maximum = magnitude
    if maximum == 0.0:
        return Float32(0.0)
    return maximum / Float32(I8_SYMMETRIC_MAX)


def encode_symmetric_i8(value: Float32, scale: Float32) raises -> Int8:
    """Round to nearest, ties away from zero, and saturate to [-127, 127]."""
    if not isfinite(value) or not isfinite(scale) or scale < 0.0:
        raise Error("I8 graph scalar and scale must be finite and non-negative")
    if scale == 0.0:
        if value != 0.0:
            raise Error("a zero I8 scale can encode only zero")
        return Int8(0)
    var scaled = value / scale
    if scaled >= 127.0:
        return Int8(127)
    if scaled <= -127.0:
        return Int8(-127)
    if scaled >= 0.0:
        return Int8(Int(scaled + 0.5))
    return Int8(Int(scaled - 0.5))


def decode_symmetric_i8(code: Int8, scale: Float32) raises -> Float32:
    if code == Int8(-128):
        raise Error("I8 graph scalar -128 is outside the symmetric domain")
    if not isfinite(scale) or scale < 0.0:
        raise Error("I8 graph scale must be finite and non-negative")
    return Float32(code) * scale


def scaled_i8_accumulator(
    accumulator: Int32, lhs_scale: Float32, rhs_scale: Float32
) -> Float32:
    """Widen a bounded I8 accumulator once, then restore both magnitudes."""
    return Float32(accumulator) * lhs_scale * rhs_scale


def i8_dot_f32(
    lhs: List[Int8],
    lhs_scale: Float32,
    rhs: List[Int8],
    rhs_scale: Float32,
) raises -> Float32:
    """Accumulate a bounded symmetric-I8 dot product and widen once to F32."""
    if len(lhs) != len(rhs):
        raise Error("I8 dot vectors must share one dimension")
    if len(lhs) > I8_MAX_SAFE_DIMENSION:
        raise Error("I8 dot dimension exceeds the Int32 accumulator bound")
    if (
        not isfinite(lhs_scale)
        or not isfinite(rhs_scale)
        or lhs_scale < 0.0
        or rhs_scale < 0.0
    ):
        raise Error("I8 dot scales must be finite and non-negative")
    var accumulator = Int32(0)
    for index in range(len(lhs)):
        if lhs[index] == Int8(-128) or rhs[index] == Int8(-128):
            raise Error("I8 graph scalar -128 is outside the symmetric domain")
        accumulator += Int32(lhs[index]) * Int32(rhs[index])
    return scaled_i8_accumulator(accumulator, lhs_scale, rhs_scale)


def normalize_for_cosine_i8(values: List[Float32]) raises -> List[Float32]:
    """Normalize with a stable Float64 norm before fixed-scale I8 encoding."""
    if len(values) == 0:
        raise Error("cosine distance requires a non-zero vector")
    var maximum = Float64(0.0)
    for value in values:
        if not isfinite(value):
            raise Error("I8 cosine vectors must be finite")
        var magnitude = abs(Float64(value))
        if magnitude > maximum:
            maximum = magnitude
    if maximum == 0.0:
        raise Error("cosine distance requires a non-zero vector")
    var scaled_sum = Float64(0.0)
    for value in values:
        var scaled = Float64(value) / maximum
        scaled_sum += scaled * scaled
    var norm = maximum * sqrt(scaled_sum)
    var result = List[Float32](capacity=len(values))
    for value in values:
        result.append(Float32(Float64(value) / norm))
    return result^
