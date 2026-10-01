from std.math import isfinite, sqrt
from std.sys import simd_width_of


def _validate_pair(lhs: List[Float32], rhs: List[Float32]) raises:
    if len(lhs) == 0:
        raise Error("vectors must not be empty")
    if len(lhs) != len(rhs):
        raise Error("vector dimensions must match")
    # Validation is part of each authoritative rerank. Check full chunks with
    # the same finite-value rule, without a scalar branch per component.
    comptime width = simd_width_of[DType.float32]() * 4
    var offset = 0
    while offset + width <= len(lhs):
        var left = lhs.unsafe_ptr().unsafe_load[width=width](offset)
        var right = rhs.unsafe_ptr().unsafe_load[width=width](offset)
        if not (isfinite(left) & isfinite(right)).reduce_and():
            raise Error("vectors must contain only finite values")
        offset += width
    while offset < len(lhs):
        if not isfinite(lhs[offset]) or not isfinite(rhs[offset]):
            raise Error("vectors must contain only finite values")
        offset += 1


def dot_product(lhs: List[Float32], rhs: List[Float32]) raises -> Float32:
    """Return the raw dot-product score for two non-empty vectors."""
    _validate_pair(lhs, rhs)

    var total: Float32 = 0.0
    for i in range(len(lhs)):
        total += lhs[i] * rhs[i]
    return total


def l2_squared_distance(
    lhs: List[Float32], rhs: List[Float32]
) raises -> Float32:
    """Return squared Euclidean distance for two non-empty vectors."""
    _validate_pair(lhs, rhs)

    var total: Float32 = 0.0
    for i in range(len(lhs)):
        var difference = lhs[i] - rhs[i]
        total += difference * difference
    return total


def cosine_similarity(lhs: List[Float32], rhs: List[Float32]) raises -> Float32:
    """Return cosine similarity, rejecting zero-norm vectors."""
    _validate_pair(lhs, rhs)

    var product: Float32 = 0.0
    var lhs_norm_squared: Float32 = 0.0
    var rhs_norm_squared: Float32 = 0.0
    for i in range(len(lhs)):
        product += lhs[i] * rhs[i]
        lhs_norm_squared += lhs[i] * lhs[i]
        rhs_norm_squared += rhs[i] * rhs[i]

    if lhs_norm_squared == 0.0 or rhs_norm_squared == 0.0:
        raise Error("cosine similarity requires non-zero vectors")

    return product / sqrt(lhs_norm_squared * rhs_norm_squared)
