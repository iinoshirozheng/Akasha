"""Python/native point-field conversion, with one owned typed authority buffer."""

from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from std.python import Python, PythonObject
from std.python.numpy import from_numpy_array
from std.memory import bitcast
from std.collections import Array
from std.ffi import c_size_t
from std.python._cpython import ExternalFunction, PyObjectPtr


comptime _Vectorcall = ExternalFunction[
    "PyObject_Vectorcall",
    def(
        PyObjectPtr, OpaquePointer[ImmutAnyOrigin], c_size_t, PyObjectPtr
    ) thin abi("C") -> PyObjectPtr,
]


def _type_check_error() raises -> Error:
    # PyErr_Fetch returns owned references. Mojo 1.0's unsafe_get_error drops
    # the type/traceback pointers without releasing them on Python 3.11.
    ref cpy = Python().cpython()
    var (error_type, error_value, traceback) = cpy.PyErr_FetchTriple()
    cpy.Py_DecRef(traceback)
    if error_value:
        cpy.Py_DecRef(error_type)
        return Error(String(py=PythonObject(from_owned=error_value)))
    return Error(String(py=PythonObject(from_owned=error_type)))


def _call_predicate(
    raw: PythonObject,
    argument: PythonObject,
    predicate: PythonObject,
    vectorcall: _Vectorcall.type,
) raises -> Bool:
    # Both Python owners and this stack argument array live through the call.
    # No kwargs or ARGUMENTS_OFFSET flag: the two borrowed slots stay read-only.
    var arguments: Array[PyObjectPtr, 2] = [raw._obj_ptr, argument._obj_ptr]
    var result = vectorcall(
        predicate._obj_ptr,
        arguments.unsafe_ptr().as_imm().unsafe_bitcast[NoneType]().unsafe_origin_cast[ImmutAnyOrigin](),
        c_size_t(2),
        PyObjectPtr(),
    )
    if not result:
        var error = _type_check_error()
        raise error^
    var owned_result = PythonObject(from_owned=result)
    var truth = Python().cpython().PyObject_IsTrue(owned_result._obj_ptr)
    if truth < 0:
        var error = _type_check_error()
        raise error^
    return truth != 0


def vector_from_python(
    raw: PythonObject, field: VectorFieldSpec
) raises -> VectorValue:
    if field.kind == 1:
        var values = List[SparseElement]()
        var builtins = Python.import_module("builtins")
        var numbers = Python.import_module("numbers")
        var is_instance = builtins.isinstance
        var vectorcall = _Vectorcall.load(Python().cpython().lib.borrow())
        var integer_type = numbers.Integral
        var real_type = numbers.Real
        var bool_type = builtins.bool
        for item in raw:
            var term = _integer(item["term_id"], is_instance, integer_type, bool_type, vectorcall)
            var weight = _real(item["weight"], is_instance, real_type, bool_type, vectorcall)
            values.append(SparseElement(term, Float32(weight)))
        return VectorValue.sparse(values^)
    if field.kind == 3:
        var values = List[UInt8]()
        var builtins = Python.import_module("builtins")
        var numbers = Python.import_module("numbers")
        var is_instance = builtins.isinstance
        var vectorcall = _Vectorcall.load(Python().cpython().lib.borrow())
        var integer_type = numbers.Integral
        var bool_type = builtins.bool
        for item in raw:
            var value = _integer(item, is_instance, integer_type, bool_type, vectorcall)
            if value < 0 or value > 255:
                raise Error("binary bytes must fit UInt8")
            values.append(UInt8(value))
        return VectorValue.binary(field.dimension, values^)
    if field.scalar == 0:
        return _numeric_from_python[DType.float32](raw, field)
    if field.scalar == 1:
        return _numeric_from_python[DType.bfloat16](raw, field)
    if field.scalar == 2:
        return _numeric_from_python[DType.float16](raw, field)
    if field.scalar == 3:
        return _numeric_from_python[DType.int8](raw, field)
    if field.scalar == 4:
        return _numeric_from_python[DType.uint8](raw, field)
    raise Error("unsupported numeric field scalar")


def _integer(
    raw: PythonObject, is_instance: PythonObject, numeric_type: PythonObject, bool_type: PythonObject, vectorcall: _Vectorcall.type
) raises -> Int:
    if not _call_predicate(raw, numeric_type, is_instance, vectorcall) or _call_predicate(
        raw, bool_type, is_instance, vectorcall
    ):
        raise Error("integer vector values must be integers")
    return Int(py=raw)


def _real(
    raw: PythonObject, is_instance: PythonObject, numeric_type: PythonObject, bool_type: PythonObject, vectorcall: _Vectorcall.type
) raises -> Float64:
    if not _call_predicate(raw, numeric_type, is_instance, vectorcall) or _call_predicate(
        raw, bool_type, is_instance, vectorcall
    ):
        raise Error("numeric vector values must be real numbers")
    return Float64(py=raw)


def _component[
    dtype: DType
](
    raw: PythonObject, is_instance: PythonObject, numeric_type: PythonObject, bool_type: PythonObject, vectorcall: _Vectorcall.type
) raises -> Scalar[dtype]:
    comptime if dtype == DType.int8 or dtype == DType.uint8:
        var value = _integer(raw, is_instance, numeric_type, bool_type, vectorcall)
        comptime if dtype == DType.int8:
            if value < -128 or value > 127:
                raise Error("integer vector value exceeds Int8")
        else:
            if value < 0 or value > 255:
                raise Error("integer vector value exceeds UInt8")
        return Scalar[dtype](value)
    else:
        return Scalar[dtype](_real(raw, is_instance, numeric_type, bool_type, vectorcall))


def _numeric_from_python[
    dtype: DType
](raw: PythonObject, field: VectorFieldSpec) raises -> VectorValue:
    var builtins = Python.import_module("builtins")
    var numbers = Python.import_module("numbers")
    var values = List[Scalar[dtype]]()
    var used_array = False
    var vectorcall = _Vectorcall.load(Python().cpython().lib.borrow())
    if _call_predicate(raw, PythonObject("dtype"), builtins.hasattr, vectorcall):
        var np = Python.import_module("numpy")
        if _call_predicate(raw, np.ndarray, builtins.isinstance, vectorcall):
            var ndim = Int(py=raw.ndim)
            if (field.kind == 0 and ndim != 1) or (
                field.kind == 2 and ndim != 2
            ):
                raise Error("native array rank does not match vector field")
            if Int(py=raw.shape[-1]) != field.dimension:
                raise Error(
                    "native array dimension does not match vector field"
                )
            var name = String(py=raw.dtype.name)
            comptime if dtype == DType.bfloat16:
                if name == "bfloat16" and Bool(py=raw.flags.c_contiguous):
                    var bits = raw.view(np.uint16).reshape(-1)
                    var view = from_numpy_array[DType.uint16](bits)
                    values.reserve(len(view))
                    for element_bits in view:
                        values.append(bitcast[dtype](element_bits))
                    used_array = True
            else:
                comptime expected = "float32" if dtype == DType.float32 else (
                    "float16" if dtype
                    == DType.float16 else (
                        "int8" if dtype == DType.int8 else "uint8"
                    )
                )
                if name == expected and Bool(py=raw.flags.c_contiguous):
                    var flat = raw.reshape(-1)
                    values.extend(from_numpy_array[dtype](flat))
                    used_array = True
    if not used_array:
        # Resolve the existing callable/types and vectorcall once per operation.
        # Every component retains both checks and its original conversion.
        var is_instance = builtins.isinstance
        var bool_type = builtins.bool
        var numeric_type = numbers.Integral if (dtype == DType.int8 or dtype == DType.uint8) else numbers.Real
        if field.kind == 0:
            if len(raw) != field.dimension:
                raise Error("vector dimension does not match field")
            values.reserve(len(raw))
            for item in raw:
                values.append(_component[dtype](item, is_instance, numeric_type, bool_type, vectorcall))
        else:
            for row in raw:
                if len(row) != field.dimension:
                    raise Error(
                        "multivector row dimension does not match field"
                    )
                for item in row:
                    values.append(_component[dtype](item, is_instance, numeric_type, bool_type, vectorcall))
    if field.kind == 0:
        return VectorValue.dense[dtype](values^)
    return VectorValue.multivector[dtype](field.dimension, values^)


def vector_to_python(value: VectorValue) raises -> PythonObject:
    if value.kind() == 1:
        var values = Python.list()
        for element in value.sparse_values():
            values.append(
                Python.dict(
                    term_id=PythonObject(element.term_id),
                    weight=PythonObject(element.weight),
                )
            )
        return values
    if value.kind() == 3:
        var values = Python.list()
        for byte in value.binary_values():
            values.append(Int(byte))
        return Python.import_module("builtins").bytes(values)
    if value.scalar() == 0:
        return _numeric_to_python[DType.float32](value)
    if value.scalar() == 1:
        return _numeric_to_python[DType.bfloat16](value)
    if value.scalar() == 2:
        return _numeric_to_python[DType.float16](value)
    if value.scalar() == 3:
        return _numeric_to_python[DType.int8](value)
    return _numeric_to_python[DType.uint8](value)


def _python_component[
    dtype: DType
](value: Scalar[dtype]) raises -> PythonObject:
    comptime if dtype == DType.int8 or dtype == DType.uint8:
        return PythonObject(Int(value))
    else:
        return PythonObject(Float64(value))


def _numeric_to_python[dtype: DType](value: VectorValue) raises -> PythonObject:
    var result = Python.list()
    if value.kind() == 0:
        for item in value.dense_values[dtype]():
            result.append(_python_component(item))
    else:
        ref values = value.multivector_values[dtype]()
        for row in range(value.row_count()):
            var output = Python.list()
            for column in range(value.dimension()):
                output.append(
                    _python_component(values[row * value.dimension() + column])
                )
            result.append(output)
    return result
