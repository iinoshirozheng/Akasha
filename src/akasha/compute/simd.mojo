from akasha.compute.distance import _validate_pair
from std.math import sqrt
from std.sys import simd_width_of


comptime _FLOAT32_SIMD_WIDTH = simd_width_of[DType.float32]()


def _dot_kernel[width: Int](lhs: List[Float32], rhs: List[Float32]) -> Float32:
    var lhs_ptr = lhs.unsafe_ptr()
    var rhs_ptr = rhs.unsafe_ptr()
    var lanes = SIMD[DType.float32, width](0.0)
    var offset = 0

    while offset + width <= len(lhs):
        lanes += lhs_ptr.unsafe_load[width=width](offset) * rhs_ptr.unsafe_load[
            width=width
        ](offset)
        offset += width

    var total = lanes.reduce_add()
    while offset < len(lhs):
        total += lhs[offset] * rhs[offset]
        offset += 1
    return total


def _l2_kernel[width: Int](lhs: List[Float32], rhs: List[Float32]) -> Float32:
    var lhs_ptr = lhs.unsafe_ptr()
    var rhs_ptr = rhs.unsafe_ptr()
    var lanes = SIMD[DType.float32, width](0.0)
    var offset = 0

    while offset + width <= len(lhs):
        var difference = lhs_ptr.unsafe_load[width=width](
            offset
        ) - rhs_ptr.unsafe_load[width=width](offset)
        lanes += difference * difference
        offset += width

    var total = lanes.reduce_add()
    while offset < len(lhs):
        var difference = lhs[offset] - rhs[offset]
        total += difference * difference
        offset += 1
    return total


def simd_dot_product(lhs: List[Float32], rhs: List[Float32]) raises -> Float32:
    """Return a hardware-width SIMD dot-product score."""
    _validate_pair(lhs, rhs)
    return _dot_kernel[_FLOAT32_SIMD_WIDTH](lhs, rhs)


def simd_l2_squared_distance(
    lhs: List[Float32], rhs: List[Float32]
) raises -> Float32:
    """Return hardware-width SIMD squared Euclidean distance."""
    _validate_pair(lhs, rhs)
    return _l2_kernel[_FLOAT32_SIMD_WIDTH](lhs, rhs)


def simd_cosine_similarity(
    lhs: List[Float32], rhs: List[Float32]
) raises -> Float32:
    """Return hardware-width SIMD cosine similarity."""
    _validate_pair(lhs, rhs)
    var product = _dot_kernel[_FLOAT32_SIMD_WIDTH](lhs, rhs)
    var lhs_norm_squared = _dot_kernel[_FLOAT32_SIMD_WIDTH](lhs, lhs)
    var rhs_norm_squared = _dot_kernel[_FLOAT32_SIMD_WIDTH](rhs, rhs)

    if lhs_norm_squared == 0.0 or rhs_norm_squared == 0.0:
        raise Error("cosine similarity requires non-zero vectors")
    return product / sqrt(lhs_norm_squared * rhs_norm_squared)


def prevalidated_simd_dot_product(
    lhs: List[Float32], rhs: List[Float32]
) -> Float32:
    """Score a pair already validated for equal, finite dimensions."""
    return _dot_kernel[_FLOAT32_SIMD_WIDTH](lhs, rhs)


def prevalidated_simd_l2_squared_distance(
    lhs: List[Float32], rhs: List[Float32]
) -> Float32:
    """Score a pair already validated for equal, finite dimensions."""
    return _l2_kernel[_FLOAT32_SIMD_WIDTH](lhs, rhs)


def prevalidated_simd_cosine_similarity(
    lhs: List[Float32], rhs: List[Float32]
) -> Float32:
    """Score a validated pair whose vectors both have non-zero norms."""
    var product = _dot_kernel[_FLOAT32_SIMD_WIDTH](lhs, rhs)
    var lhs_norm_squared = _dot_kernel[_FLOAT32_SIMD_WIDTH](lhs, lhs)
    var rhs_norm_squared = _dot_kernel[_FLOAT32_SIMD_WIDTH](rhs, rhs)
    return product / sqrt(lhs_norm_squared * rhs_norm_squared)
