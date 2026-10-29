"""Portable recommendation scorer from Qdrant's metric/query-scorer sources.

Revision 74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0.
Preprocess each query row before target-datatype conversion; custom scorers use
internal similarity, never public Euclidean distance. Native raw authority is
not mutated. BF16/I8 are Akasha extensions to Qdrant's F32/F16/U8 types.
"""

from akasha.compute.f32 import rounded_f32_product
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from std.math import inf, sqrt


def _float_values[dtype: DType](value: VectorValue) raises -> List[Float32]:
    var result = List[Float32]()
    if value.kind() == 0:
        for item in value.dense_values[dtype]():
            result.append(Float32(item))
    else:
        for item in value.multivector_values[dtype]():
            result.append(Float32(item))
    return result^


def recommendation_input(value: VectorValue) raises -> VectorValue:
    if value.kind() == 1:
        return VectorValue.sparse(value.sparse_values().copy())
    if value.kind() == 3:
        raise Error("binary recommendation is not supported by Qdrant")
    var values: List[Float32]
    if value.scalar() == 0:
        values = _float_values[DType.float32](value)
    elif value.scalar() == 1:
        values = _float_values[DType.bfloat16](value)
    elif value.scalar() == 2:
        values = _float_values[DType.float16](value)
    elif value.scalar() == 3:
        values = _float_values[DType.int8](value)
    else:
        values = _float_values[DType.uint8](value)
    if value.kind() == 0:
        return VectorValue.dense[DType.float32](values^)
    return VectorValue.multivector[DType.float32](value.dimension(), values^)


def prepare_recommendation_vector(value: VectorValue, field: VectorFieldSpec) raises -> VectorValue:
    if value.kind() != field.kind or (field.kind != 1 and value.dimension() != field.dimension):
        raise Error("recommendation vector kind or dimension mismatch")
    if field.kind == 1:
        return VectorValue.sparse(value.sparse_values().copy())
    var float_value = recommendation_input(value)
    var values = _float_values[DType.float32](float_value)
    var dimension = value.dimension()
    if field.metric == 2 and field.scalar < 3:
        for row in range(len(values) // dimension):
            var start = row * dimension
            var length = Float32(0)
            for i in range(dimension):
                length += rounded_f32_product(values[start + i], values[start + i])
            # spaces/tools.rs::is_length_zero_or_normalized
            if length < Float32(1.1920928955078125e-7) or abs(length - Float32(1)) <= Float32(1e-6):
                continue
            length = sqrt(length)
            for i in range(dimension):
                values[start + i] /= length
    for i in range(len(values)):
        if field.scalar == 1:
            values[i] = Float32(BFloat16(values[i]))
        elif field.scalar == 2:
            values[i] = Float32(Float16(values[i]))
        elif field.scalar == 3:
            values[i] = Float32(Int8(max(Float32(-128), min(Float32(127), values[i]))))
        elif field.scalar == 4:
            # Rust float as u8 saturates and truncates rather than rounding.
            values[i] = Float32(UInt8(max(Float32(0), min(Float32(255), values[i]))))
    if value.kind() == 0:
        return VectorValue.dense[DType.float32](values^)
    return VectorValue.multivector[DType.float32](dimension, values^)


def _row_similarity(
    query: List[Float32], candidate: List[Float32], qi: Int, ci: Int,
    field: VectorFieldSpec,
) -> Float32:
    var total = Float32(0)
    var integer_total = Int64(0)
    var qnorm = Int64(0)
    var cnorm = Int64(0)
    for i in range(field.dimension):
        var a = query[qi + i]
        var b = candidate[ci + i]
        if field.scalar >= 3:
            var ai = Int64(a)
            var bi = Int64(b)
            if field.metric == 1:
                integer_total += (ai - bi) * (ai - bi)
            else:
                integer_total += ai * bi
            qnorm += ai * ai
            cnorm += bi * bi
        elif field.metric == 1:
            var difference = a - b
            total += rounded_f32_product(difference, difference)
        else:
            total += rounded_f32_product(a, b)
    if field.scalar >= 3:
        total = Float32(integer_total)
        if field.metric == 2:
            if qnorm == 0 or cnorm == 0:
                return 0
            total /= sqrt(Float32(qnorm) * Float32(cnorm))
    return -total if field.metric == 1 else total


def recommendation_similarity(query: VectorValue, candidate: VectorValue, field: VectorFieldSpec) raises -> Float32:
    if field.kind == 1:
        ref left = query.sparse_values()
        ref right = candidate.sparse_values()
        var i = 0
        var j = 0
        var total = Float32(0)
        while i < len(left) and j < len(right):
            if left[i].term_id < right[j].term_id:
                i += 1
            elif left[i].term_id > right[j].term_id:
                j += 1
            else:
                total += rounded_f32_product(left[i].weight, right[j].weight)
                i += 1
                j += 1
        return total
    if field.kind == 0:
        return _row_similarity(query.dense_values[DType.float32](), candidate.dense_values[DType.float32](), 0, 0, field)
    ref left = query.multivector_values[DType.float32]()
    ref right = candidate.multivector_values[DType.float32]()
    var total = Float32(0)
    for qrow in range(query.row_count()):
        var best = -inf[DType.float32]()
        for crow in range(candidate.row_count()):
            best = max(best, _row_similarity(left, right, qrow * field.dimension, crow * field.dimension, field))
        total += best
    return total
