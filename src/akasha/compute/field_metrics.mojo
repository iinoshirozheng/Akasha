from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from std.bit import pop_count
from std.math import sqrt


def validate_field_query(query: VectorValue, field: VectorFieldSpec) raises:
    query.validate(field)
    if field.kind == 2 and query.row_count() == 0:
        raise Error("MaxSim query requires at least one row")
    if field.metric == 2:
        # Check every query row even when the searched field has no points.
        if field.scalar == 0:
            _validate_cosine_query[DType.float32](query)
        elif field.scalar == 1:
            _validate_cosine_query[DType.bfloat16](query)
        elif field.scalar == 2:
            _validate_cosine_query[DType.float16](query)
        elif field.scalar == 3:
            _validate_cosine_query[DType.int8](query)
        else:
            _validate_cosine_query[DType.uint8](query)


def _validate_cosine_query[dtype: DType](query: VectorValue) raises:
    if query.kind() == 0:
        var row = Span(query.dense_values[dtype]())
        _ = _numeric_score[dtype](2, row, row)
        return
    ref values = query.multivector_values[dtype]()
    var dimension = query.dimension()
    for index in range(query.row_count()):
        var row = Span(values)[index * dimension : (index + 1) * dimension]
        _ = _numeric_score[dtype](2, row, row)


def score_vector_field(
    query: VectorValue, candidate: VectorValue, field: VectorFieldSpec
) raises -> Float64:
    """Raw score: Dot/cosine high-first; squared L2/Hamming/Jaccard low-first.

    Accumulate in Float64 without changing native stored scalars. Jaccard is
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
        var total = Float64(0)
        while left < len(lhs) and right < len(rhs):
            if lhs[left].term_id < rhs[right].term_id:
                left += 1
            elif lhs[left].term_id > rhs[right].term_id:
                right += 1
            else:
                total += Float64(lhs[left].weight) * Float64(rhs[right].weight)
                left += 1
                right += 1
        return total
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
    var total = Float64(0)
    var left_norm = Float64(0)
    var right_norm = Float64(0)
    for index in range(len(lhs)):
        var left = Float64(lhs[index])
        var right = Float64(rhs[index])
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
            raise Error("cosine similarity requires non-zero vectors")
        return total / (sqrt(left_norm) * sqrt(right_norm))
    return total
