from std.math import isfinite, sqrt
from std.sys import simd_width_of


comptime EXACT_SIMD_GROUPS = 4
comptime EXACT_WIDE_MIN_DIMENSION = 64


comptime _FLOAT32_SIMD_WIDTH = simd_width_of[DType.float32]()


def _checked_kernel[
    metric: Int, width: Int, query_prepared: Bool = False
](
    lhs: List[Float32], rhs: List[Float32], prepared_norm: Float32 = 0
) raises -> Float32:
    """Validate while scoring, preserving the established accumulator order."""
    if len(lhs) == 0:
        raise Error("vectors must not be empty")
    if len(lhs) != len(rhs):
        raise Error("vector dimensions must match")
    var total = SIMD[DType.float32, width](0)
    var left_norm = SIMD[DType.float32, width](0)
    var right_norm = SIMD[DType.float32, width](0)
    var valid = SIMD[DType.bool, width](fill=True)
    var offset = 0
    while offset + width <= len(lhs):
        var left = lhs.unsafe_ptr().unsafe_load[width=width](offset)
        var right = rhs.unsafe_ptr().unsafe_load[width=width](offset)
        comptime if query_prepared:
            valid &= isfinite(right)
        else:
            valid &= isfinite(left) & isfinite(right)
        comptime if metric == 1:
            var difference = left - right
            total += difference * difference
        else:
            total += left * right
            comptime if metric == 2:
                comptime if not query_prepared:
                    left_norm += left * left
                right_norm += right * right
        offset += width
    if not valid.reduce_and():
        raise Error("vectors must contain only finite values")
    var score = total.reduce_add()
    var lhs_norm = prepared_norm
    comptime if not query_prepared:
        lhs_norm = left_norm.reduce_add()
    var rhs_norm = right_norm.reduce_add()
    while offset < len(lhs):
        var left = lhs[offset]
        var right = rhs[offset]
        comptime if query_prepared:
            if not isfinite(right):
                raise Error("vectors must contain only finite values")
        else:
            if not isfinite(left) or not isfinite(right):
                raise Error("vectors must contain only finite values")
        comptime if metric == 1:
            var difference = left - right
            score += difference * difference
        else:
            score += left * right
            comptime if metric == 2:
                comptime if not query_prepared:
                    lhs_norm += left * left
                rhs_norm += right * right
        offset += 1
    comptime if metric == 2:
        if lhs_norm == 0 or rhs_norm == 0:
            raise Error("cosine similarity requires non-zero vectors")
        return score / sqrt(lhs_norm * rhs_norm)
    else:
        return score


def _checked_score[
    metric: Int
](lhs: List[Float32], rhs: List[Float32]) raises -> Float32:
    if len(lhs) >= EXACT_WIDE_MIN_DIMENSION:
        return _checked_kernel[metric, _FLOAT32_SIMD_WIDTH * EXACT_SIMD_GROUPS](
            lhs, rhs
        )
    return _checked_kernel[metric, _FLOAT32_SIMD_WIDTH](lhs, rhs)


def _prepare_query_kernel[
    cosine: Bool, width: Int
](query: List[Float32]) raises -> Float32:
    if len(query) == 0:
        raise Error("vectors must not be empty")
    var norm = SIMD[DType.float32, width](0)
    var valid = SIMD[DType.bool, width](fill=True)
    var offset = 0
    while offset + width <= len(query):
        var values = query.unsafe_ptr().unsafe_load[width=width](offset)
        valid &= isfinite(values)
        comptime if cosine:
            norm += values * values
        offset += width
    if not valid.reduce_and():
        raise Error("vectors must contain only finite values")
    var result = norm.reduce_add()
    while offset < len(query):
        var value = query[offset]
        if not isfinite(value):
            raise Error("vectors must contain only finite values")
        comptime if cosine:
            result += value * value
        offset += 1
    # Keep zero-norm rejection in scoring, after candidate validation.
    return result


def _prepare_f32_query(metric: Int, query: List[Float32]) raises -> Float32:
    """Validate an exact-scan query and prepare its F32 cosine squared norm.

    The caller must keep this query and metric unchanged until all prepared
    scores finish. This scalar stores no pointer, owner or persistent state.
    Dot and L2 only validate finiteness and return zero.
    """
    if len(query) >= EXACT_WIDE_MIN_DIMENSION:
        if metric == 0 or metric == 1:
            return _prepare_query_kernel[
                False, _FLOAT32_SIMD_WIDTH * EXACT_SIMD_GROUPS
            ](query)
        return _prepare_query_kernel[
            True, _FLOAT32_SIMD_WIDTH * EXACT_SIMD_GROUPS
        ](query)
    if metric == 0 or metric == 1:
        return _prepare_query_kernel[False, _FLOAT32_SIMD_WIDTH](query)
    return _prepare_query_kernel[True, _FLOAT32_SIMD_WIDTH](query)


def _prepared_score[
    metric: Int
](
    query: List[Float32], candidate: List[Float32], query_norm: Float32
) raises -> Float32:
    if len(query) >= EXACT_WIDE_MIN_DIMENSION:
        return _checked_kernel[
            metric, _FLOAT32_SIMD_WIDTH * EXACT_SIMD_GROUPS, True
        ](query, candidate, query_norm)
    return _checked_kernel[metric, _FLOAT32_SIMD_WIDTH, True](
        query, candidate, query_norm
    )


def _prepared_f32_score(
    metric: Int,
    query: List[Float32],
    candidate: List[Float32],
    query_norm: Float32,
) raises -> Float32:
    """Score the unchanged prepared query, validating each candidate fully."""
    if metric == 0:
        return _prepared_score[0](query, candidate, query_norm)
    if metric == 1:
        return _prepared_score[1](query, candidate, query_norm)
    return _prepared_score[2](query, candidate, query_norm)


def _checked_pair_kernel[metric: Int, width: Int](
    query: List[Float32], first: List[Float32], second: List[Float32],
    query_norm: Float32,
) raises -> SIMD[DType.float32, 2]:
    if len(query) == 0:
        raise Error("vectors must not be empty")
    if len(first) != len(query):
        raise Error("vector dimensions must match")
    if len(second) != len(query):
        # Preserve the earlier candidate's finite/zero-norm error precedence.
        _ = _prepared_score[metric](query, first, query_norm)
        raise Error("vector dimensions must match")
    var total0 = SIMD[DType.float32, width](0)
    var total1 = SIMD[DType.float32, width](0)
    var norm0 = SIMD[DType.float32, width](0)
    var norm1 = SIMD[DType.float32, width](0)
    var valid0 = SIMD[DType.bool, width](fill=True)
    var valid1 = SIMD[DType.bool, width](fill=True)
    var offset = 0
    while offset + width <= len(query):
        var left = query.unsafe_ptr().unsafe_load[width=width](offset)
        var right0 = first.unsafe_ptr().unsafe_load[width=width](offset)
        var right1 = second.unsafe_ptr().unsafe_load[width=width](offset)
        valid0 &= isfinite(right0)
        valid1 &= isfinite(right1)
        comptime if metric == 1:
            var difference0 = left - right0
            var difference1 = left - right1
            total0 += difference0 * difference0
            total1 += difference1 * difference1
        else:
            total0 += left * right0
            total1 += left * right1
            comptime if metric == 2:
                norm0 += right0 * right0
                norm1 += right1 * right1
        offset += width
    if not valid0.reduce_and():
        raise Error("vectors must contain only finite values")
    var score0 = total0.reduce_add()
    var score1 = total1.reduce_add()
    var squared_norm0 = norm0.reduce_add()
    var squared_norm1 = norm1.reduce_add()
    var tail_valid1 = True
    while offset < len(query):
        var left = query[offset]
        var right0 = first[offset]
        var right1 = second[offset]
        if not isfinite(right0):
            raise Error("vectors must contain only finite values")
        tail_valid1 = tail_valid1 and isfinite(right1)
        comptime if metric == 1:
            var difference0 = left - right0
            var difference1 = left - right1
            score0 += difference0 * difference0
            score1 += difference1 * difference1
        else:
            score0 += left * right0
            score1 += left * right1
            comptime if metric == 2:
                squared_norm0 += right0 * right0
                squared_norm1 += right1 * right1
        offset += 1
    comptime if metric == 2:
        if query_norm == 0 or squared_norm0 == 0:
            raise Error("cosine similarity requires non-zero vectors")
        score0 = score0 / sqrt(query_norm * squared_norm0)
    if not valid1.reduce_and() or not tail_valid1:
        raise Error("vectors must contain only finite values")
    comptime if metric == 2:
        if query_norm == 0 or squared_norm1 == 0:
            raise Error("cosine similarity requires non-zero vectors")
        score1 = score1 / sqrt(query_norm * squared_norm1)
    return SIMD[DType.float32, 2](score0, score1)


def _prepared_pair_score[metric: Int](
    query: List[Float32], first: List[Float32], second: List[Float32],
    query_norm: Float32,
) raises -> SIMD[DType.float32, 2]:
    comptime assert metric >= 0 and metric <= 2
    comptime width = simd_width_of[DType.float32]()
    if len(query) >= EXACT_WIDE_MIN_DIMENSION:
        return _checked_pair_kernel[metric, width * EXACT_SIMD_GROUPS](
            query, first, second, query_norm
        )
    return _checked_pair_kernel[metric, width](query, first, second, query_norm)


def _prepared_f32_pair_score(
    metric: Int, query: List[Float32], first: List[Float32],
    second: List[Float32], query_norm: Float32,
) raises -> SIMD[DType.float32, 2]:
    """Score two owned candidates in order, preserving every row check."""
    if metric == 0:
        return _prepared_pair_score[0](query, first, second, query_norm)
    if metric == 1:
        return _prepared_pair_score[1](query, first, second, query_norm)
    return _prepared_pair_score[2](query, first, second, query_norm)


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
    return _checked_score[0](lhs, rhs)


def _simd_dot_product_unchecked(
    lhs: List[Float32], rhs: List[Float32]
) -> Float32:
    """Return a SIMD dot product for prevalidated vectors.

    Callers must guarantee non-empty, equal-length, finite inputs.
    """
    # Four native register groups shorten the accumulator dependency chain.
    # Retain the narrow loop for short vectors to avoid a long scalar tail.
    if len(lhs) >= EXACT_WIDE_MIN_DIMENSION:
        return _dot_kernel[_FLOAT32_SIMD_WIDTH * EXACT_SIMD_GROUPS](lhs, rhs)
    return _dot_kernel[_FLOAT32_SIMD_WIDTH](lhs, rhs)


def simd_l2_squared_distance(
    lhs: List[Float32], rhs: List[Float32]
) raises -> Float32:
    """Return hardware-width SIMD squared Euclidean distance."""
    return _checked_score[1](lhs, rhs)


def _simd_l2_squared_unchecked(
    lhs: List[Float32], rhs: List[Float32]
) -> Float32:
    """Return SIMD squared L2 distance for prevalidated vectors.

    Callers must guarantee non-empty, equal-length, finite inputs.
    """
    if len(lhs) >= EXACT_WIDE_MIN_DIMENSION:
        return _l2_kernel[_FLOAT32_SIMD_WIDTH * EXACT_SIMD_GROUPS](lhs, rhs)
    return _l2_kernel[_FLOAT32_SIMD_WIDTH](lhs, rhs)


def simd_cosine_similarity(
    lhs: List[Float32], rhs: List[Float32]
) raises -> Float32:
    """Return hardware-width SIMD cosine similarity."""
    return _checked_score[2](lhs, rhs)


def prevalidated_simd_dot_product(
    lhs: List[Float32], rhs: List[Float32]
) -> Float32:
    """Compatibility name for the single unchecked dot implementation."""
    return _simd_dot_product_unchecked(lhs, rhs)


def prevalidated_simd_l2_squared_distance(
    lhs: List[Float32], rhs: List[Float32]
) -> Float32:
    """Compatibility name for the single unchecked L2 implementation."""
    return _simd_l2_squared_unchecked(lhs, rhs)


def prevalidated_simd_cosine_similarity(
    lhs: List[Float32], rhs: List[Float32]
) -> Float32:
    """Score a validated pair whose vectors both have non-zero norms."""
    var product = _simd_dot_product_unchecked(lhs, rhs)
    var lhs_norm_squared = _simd_dot_product_unchecked(lhs, lhs)
    var rhs_norm_squared = _simd_dot_product_unchecked(rhs, rhs)
    return product / sqrt(lhs_norm_squared * rhs_norm_squared)
