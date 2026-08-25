from std.math import sqrt


def _validate_pair(lhs: List[Float32], rhs: List[Float32]) raises:
    if len(lhs) == 0:
        raise Error("vectors must not be empty")
    if len(lhs) != len(rhs):
        raise Error("vector dimensions must match")


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
