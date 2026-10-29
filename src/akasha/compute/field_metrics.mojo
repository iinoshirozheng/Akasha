from akasha.compute.f32 import rounded_f32_product
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from std.bit import pop_count
from std.math import abs, sqrt
from std.iter import zip


def validate_field_query(query: VectorValue, field: VectorFieldSpec) raises:
    query.validate(field)
    if field.kind == 2 and query.row_count() == 0:
        raise Error("MaxSim query requires at least one row")


def score_vector_field(
    query: VectorValue, candidate: VectorValue, field: VectorFieldSpec
) raises -> Float64:
    """Raw score: Dot/cosine high-first; squared L2/Hamming/Jaccard low-first.

    Dense and multivector scores accumulate in Float64, except F16 cosine:
    it normalizes/rounds to half before Float32 dot scoring, as in Qdrant.
    Sparse Dot uses Float32 accumulation without changing stored scalars. Jaccard is
    distance, with two zero bitsets at distance zero. MaxSim sums each query
    row's best match (minimum squared L2 or maximum Dot/cosine). Empty matrices
    remain valid stored values but cannot score against a nonempty query.
    """
    validate_field_query(query, field)
    candidate.validate(field)
    return _score_validated_field(query, candidate, field)


def _score_validated_field(
    query: VectorValue, candidate: VectorValue, field: VectorFieldSpec
) raises -> Float64:
    if field.kind == 3:
        ref lhs = query.binary_values()
        ref rhs = candidate.binary_values()
        var different = UInt64(0)
        var intersection = UInt64(0)
        var union = UInt64(0)
        for index in range(len(lhs)):
            if field.metric == 3:
                different += UInt64(pop_count(lhs[index] ^ rhs[index]))
            else:
                intersection += UInt64(pop_count(lhs[index] & rhs[index]))
                union += UInt64(pop_count(lhs[index] | rhs[index]))
        if field.metric == 3:
            return Float64(different)
        return Float64(0) if union == 0 else Float64(1) - Float64(
            intersection
        ) / Float64(union)
    if field.kind == 1:
        ref lhs = query.sparse_values()
        ref rhs = candidate.sparse_values()
        var left = 0
        var right = 0
        var total = Float32(0)
        while left < len(lhs) and right < len(rhs):
            if lhs[left].term_id < rhs[right].term_id:
                left += 1
            elif lhs[left].term_id > rhs[right].term_id:
                right += 1
            else:
                total += rounded_f32_product(lhs[left].weight, rhs[right].weight)
                left += 1
                right += 1
        return Float64(total)
    if field.scalar == 0:
        return _score_numeric_field[DType.float32](query, candidate, field)
    if field.scalar == 1:
        return _score_numeric_field[DType.bfloat16](query, candidate, field)
    if field.scalar == 2:
        return _score_numeric_field[DType.float16](query, candidate, field)
    if field.scalar == 3:
        return _score_numeric_field[DType.int8](query, candidate, field)
    return _score_numeric_field[DType.uint8](query, candidate, field)


def _score_numeric_field[
    dtype: DType
](
    query: VectorValue, candidate: VectorValue, field: VectorFieldSpec
) raises -> Float64:
    if field.kind == 0:
        return _numeric_score[dtype](
            field.metric,
            Span(query.dense_values[dtype]()),
            Span(candidate.dense_values[dtype]()),
        )
    var query_rows = query.row_count()
    var candidate_rows = candidate.row_count()
    if query_rows == 0 or candidate_rows == 0:
        raise Error("MaxSim scoring requires nonempty matrices")
    ref lhs = query.multivector_values[dtype]()
    ref rhs = candidate.multivector_values[dtype]()
    var dimension = field.dimension
    var total = Float64(0)
    for row in range(query_rows):
        var left = Span(lhs)[row * dimension : (row + 1) * dimension]
        var best = _numeric_score[dtype](
            field.metric, left, Span(rhs)[:dimension]
        )
        for other in range(1, candidate_rows):
            var score = _numeric_score[dtype](
                field.metric,
                left,
                Span(rhs)[other * dimension : (other + 1) * dimension],
            )
            best = min(best, score) if field.metric == 1 else max(best, score)
        total += best
    return total


def _numeric_score[
    dtype: DType
](
    metric: UInt8, lhs: Span[Scalar[dtype], _], rhs: Span[Scalar[dtype], _]
) raises -> Float64:
    # Validate before zip so a malformed pair cannot silently truncate.
    if len(lhs) != len(rhs):
        raise Error("native metric dimension mismatch")
    comptime if dtype == DType.float16:
        if metric == 2:
            return _f16_cosine[dtype](lhs, rhs)
    var total = Float64(0)
    var left_norm = Float64(0)
    var right_norm = Float64(0)
    for left_value, right_value in zip(lhs, rhs):
        var left = Float64(left_value)
        var right = Float64(right_value)
        if metric == 1:
            var difference = left - right
            total += difference * difference
        else:
            total += left * right
            if metric == 2:
                left_norm += left * left
                right_norm += right * right
    if metric == 2:
        if left_norm == 0 or right_norm == 0:
            return 0
        return total / (sqrt(left_norm) * sqrt(right_norm))
    return total


def _f16_cosine[dtype: DType](
    lhs: Span[Scalar[dtype], _], rhs: Span[Scalar[dtype], _]
) -> Float64:
    """Qdrant metric_f16/simple_cosine.rs: F32 normalize, half-round, F32 dot.

    Derive prepared scalars from native half authority without rewriting the
    stored vector. Dot products of half scalars are exact in F32 before summing.
    """
    comptime assert dtype == DType.float16, "half cosine requires native half scalars"
    var left_length = Float32(0)
    var right_length = Float32(0)
    for index in range(len(lhs)):
        var left = Float32(lhs[index])
        var right = Float32(rhs[index])
        left_length += left * left
        right_length += right * right
    var left_divisor = Float32(1)
    var right_divisor = Float32(1)
    if left_length >= Float32(1.1920928955078125e-7) and abs(left_length - 1) > 1.0e-6:
        left_divisor = sqrt(left_length)
    if right_length >= Float32(1.1920928955078125e-7) and abs(right_length - 1) > 1.0e-6:
        right_divisor = sqrt(right_length)
    var total = Float32(0)
    for index in range(len(lhs)):
        var left = Float32(Float16(Float32(lhs[index]) / left_divisor))
        var right = Float32(Float16(Float32(rhs[index]) / right_divisor))
        total += left * right
    return Float64(total)


def _score_four_validated_dense(
    query: VectorValue,
    a: VectorValue,
    b: VectorValue,
    c: VectorValue,
    d: VectorValue,
    field: VectorFieldSpec,
) raises -> SIMD[DType.float64, 4]:
    """Score four native dense candidates without reordering any row's sum."""
    if field.kind != 0:
        raise Error("four-candidate scoring requires a dense field")
    if field.scalar == 0:
        return _score_numeric_dense_four[DType.float32](field.metric, query, a, b, c, d)
    if field.scalar == 1:
        return _score_numeric_dense_four[DType.bfloat16](field.metric, query, a, b, c, d)
    if field.scalar == 2:
        return _score_numeric_dense_four[DType.float16](field.metric, query, a, b, c, d)
    if field.scalar == 3:
        return _score_numeric_dense_four[DType.int8](field.metric, query, a, b, c, d)
    return _score_numeric_dense_four[DType.uint8](field.metric, query, a, b, c, d)


def _score_numeric_dense_four[dtype: DType](
    metric: UInt8,
    query: VectorValue,
    a: VectorValue,
    b: VectorValue,
    c: VectorValue,
    d: VectorValue,
) raises -> SIMD[DType.float64, 4]:
    ref lhs = query.dense_values[dtype]()
    ref r0 = a.dense_values[dtype]()
    ref r1 = b.dense_values[dtype]()
    ref r2 = c.dense_values[dtype]()
    ref r3 = d.dense_values[dtype]()
    var size = len(lhs)
    if len(r0) != size or len(r1) != size or len(r2) != size or len(r3) != size:
        raise Error("native metric dimension mismatch")
    comptime if dtype == DType.float16:
        if metric == 2:
            return SIMD[DType.float64, 4](
                _f16_cosine[dtype](Span(lhs), Span(r0)),
                _f16_cosine[dtype](Span(lhs), Span(r1)),
                _f16_cosine[dtype](Span(lhs), Span(r2)),
                _f16_cosine[dtype](Span(lhs), Span(r3)),
            )
    var total = SIMD[DType.float64, 4](0)
    var left_norm = Float64(0)
    var right_norm = SIMD[DType.float64, 4](0)
    for index in range(size):
        var left = Float64(lhs[index])
        var right = SIMD[DType.float64, 4](0)
        right[0] = Float64(r0[index])
        right[1] = Float64(r1[index])
        right[2] = Float64(r2[index])
        right[3] = Float64(r3[index])
        if metric == 1:
            var difference = SIMD[DType.float64, 4](left) - right
            total = difference.fma(difference, total)
        else:
            total = SIMD[DType.float64, 4](left).fma(right, total)
            if metric == 2:
                left_norm += left * left
                right_norm = right.fma(right, right_norm)
    if metric == 2:
        for lane in range(4):
            total[lane] = 0 if left_norm == 0 or right_norm[lane] == 0 else total[lane] / (sqrt(left_norm) * sqrt(right_norm[lane]))
        return total
    return total
