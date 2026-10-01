"""F32 projections for derived dense indexes; authority keeps its native dtype."""

from akasha.document.vector_value import VectorValue


def _convert[dtype: DType](value: VectorValue) raises -> List[Float32]:
    ref source = value.dense_values[dtype]()
    var result = List[Float32](capacity=len(source))
    for component in source:
        result.append(Float32(component))
    return result^


def dense_f32_projection(value: VectorValue) raises -> List[Float32]:
    if value.scalar() == 0:
        return value.dense_values[DType.float32]().copy()
    if value.scalar() == 1:
        return _convert[DType.bfloat16](value)
    if value.scalar() == 2:
        return _convert[DType.float16](value)
    if value.scalar() == 3:
        return _convert[DType.int8](value)
    return _convert[DType.uint8](value)
