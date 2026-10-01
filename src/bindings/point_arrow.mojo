"""Typed Arrow primitive borrows, validated before point batch publication."""

from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from std.memory import bitcast
from std.python import PythonObject
from std.python.numpy import from_numpy_array


def arrow_vector_is_valid(descriptor: PythonObject, row: Int) raises -> Bool:
    if row < 0 or row >= Int(py=descriptor["row_count"]):
        raise Error("Arrow vector row out of bounds")
    return _valid_bit(descriptor, row)


def _valid_bit(descriptor: PythonObject, index: Int) raises -> Bool:
    var bits = from_numpy_array[DType.uint8](descriptor["validity"])
    var offset = Int(py=descriptor["validity_offset"])
    if offset < 0 or index < 0 or index > Int.MAX - offset:
        raise Error("Arrow validity offset is invalid")
    if len(bits) == 0:
        return True
    var bit = offset + index
    if bit // 8 >= len(bits):
        raise Error("Arrow validity bitmap is too short")
    return (bits[bit // 8] & (UInt8(1) << UInt8(bit % 8))) != 0


def _require_valid(descriptor: PythonObject, begin: Int, end: Int) raises:
    var bits = from_numpy_array[DType.uint8](descriptor["validity"])
    var offset = Int(py=descriptor["validity_offset"])
    if offset < 0 or begin < 0 or end < begin or end > Int.MAX - offset:
        raise Error("Arrow validity range is invalid")
    if len(bits) == 0 or begin == end:
        return
    if (offset + end - 1) // 8 >= len(bits):
        raise Error("Arrow validity bitmap is too short")
    for index in range(offset + begin, offset + end):
        if (bits[index // 8] & (UInt8(1) << UInt8(index % 8))) == 0:
            raise Error("present vector cannot contain null components")


def _range(descriptor: PythonObject, row: Int) raises -> Tuple[Int, Int]:
    var offsets = from_numpy_array[DType.int32](descriptor["offsets"])
    if row < 0 or row + 1 >= len(offsets):
        raise Error("Arrow vector offset buffer is too short")
    var begin = Int(offsets[row])
    var end = Int(offsets[row + 1])
    if begin < 0 or end < begin:
        raise Error("Arrow vector offsets must be nonnegative and ascending")
    return (begin, end)


def _numeric[
    dtype: DType, physical: DType = dtype
](
    descriptor: PythonObject,
    field: VectorFieldSpec,
    row: Int,
) raises -> VectorValue:
    var first = row
    var last = row + 1
    if field.kind == 2:
        var bounds = _range(descriptor, row)
        first = bounds[0]
        last = bounds[1]
        _require_valid(descriptor["elements"], first, last)
    if last > Int.MAX // field.dimension:
        raise Error("Arrow vector dimension overflows buffer range")
    var begin = first * field.dimension
    var end = last * field.dimension
    var components = descriptor["components"]
    var source = from_numpy_array[physical](components["values"])
    if end > len(source):
        raise Error("Arrow vector value buffer is too short")
    _require_valid(components, begin, end)
    var values = List[Scalar[dtype]](capacity=end - begin)
    comptime if dtype == physical:
        var native = from_numpy_array[dtype](components["values"])
        values.extend(native[begin:end])
    else:
        for index in range(begin, end):
            values.append(bitcast[dtype](source[index]))
    if field.kind == 0:
        return VectorValue.dense[dtype](values^)
    return VectorValue.multivector[dtype](field.dimension, values^)


def vector_from_arrow(
    descriptor: PythonObject,
    field: VectorFieldSpec,
    row: Int,
) raises -> VectorValue:
    if field.kind == 3:
        var source = from_numpy_array[DType.uint8](descriptor["values"])
        var width = (field.dimension + 7) // 8
        if row >= Int.MAX // width or (row + 1) * width > len(source):
            raise Error("Arrow binary buffer is too short")
        var values = List[UInt8](capacity=width)
        values.extend(source[row * width : (row + 1) * width])
        return VectorValue.binary(field.dimension, values^)
    if field.kind == 1:
        var bounds = _range(descriptor, row)
        var begin = bounds[0]
        var end = bounds[1]
        var terms = from_numpy_array[DType.int64](descriptor["terms"]["values"])
        var weights = from_numpy_array[DType.float32](
            descriptor["weights"]["values"]
        )
        if end > len(terms) or end > len(weights):
            raise Error("Arrow sparse value buffer is too short")
        _require_valid(descriptor["elements"], begin, end)
        _require_valid(descriptor["terms"], begin, end)
        _require_valid(descriptor["weights"], begin, end)
        var values = List[SparseElement](capacity=end - begin)
        for index in range(begin, end):
            values.append(SparseElement(Int(terms[index]), weights[index]))
        return VectorValue.sparse(values^)
    if field.scalar == 0:
        return _numeric[DType.float32](descriptor, field, row)
    if field.scalar == 1:
        return _numeric[DType.bfloat16, DType.uint16](descriptor, field, row)
    if field.scalar == 2:
        return _numeric[DType.float16](descriptor, field, row)
    if field.scalar == 3:
        return _numeric[DType.int8](descriptor, field, row)
    return _numeric[DType.uint8](descriptor, field, row)
