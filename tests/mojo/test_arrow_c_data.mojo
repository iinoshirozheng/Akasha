from bindings.arrow_c_data import (
    ArrowArrayDescriptor,
    ArrowConsumerLease,
    validate_fixed_size_vectors,
    validate_sparse_offsets,
)
from std.python import Python, PythonObject
from std.python.numpy import from_numpy_array
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def test_arrow_descriptors_validate_vectors_offsets_and_nulls() raises:
    var rows = ArrowArrayDescriptor(2, 1, 0, 3)
    var values = ArrowArrayDescriptor(6, 0, 0, 6)
    validate_fixed_size_vectors(rows, values, 3)
    validate_sparse_offsets([0, 2, 3], 3, 3)

    with assert_raises():
        _ = ArrowArrayDescriptor(2, 3, 0, 4)
    with assert_raises():
        validate_fixed_size_vectors(
            ArrowArrayDescriptor(2, 0, 1, 2), values, 3
        )
    with assert_raises():
        validate_sparse_offsets([0, 2, 2], 2, 2)


def test_arrow_consumer_release_callback_is_exactly_once() raises:
    var lease = ArrowConsumerLease()
    lease.ensure_active()
    assert_false(lease.released())
    lease.release()
    assert_true(lease.released())
    assert_equal(lease.release_callback_calls(), 1)
    with assert_raises():
        lease.ensure_active()
    with assert_raises():
        lease.release()
    assert_equal(lease.release_callback_calls(), 1)


def _check_typed_borrow[dtype: DType](
    array: PythonObject, expected_address: Int
) raises:
    var values = from_numpy_array[dtype](array)
    assert_equal(Int(values.unsafe_ptr()), expected_address)
    assert_equal(len(values), 3)
    assert_equal(values[0], Scalar[dtype](2))
    assert_equal(values[2], Scalar[dtype](4))


def test_arrow_numpy_native_span_pointer_identity_and_readonly() raises:
    var np = Python.import_module("numpy")
    var pa = Python.import_module("pyarrow")
    var floats = pa.array(np.arange(8, dtype="float32")).slice(2, 3)
    var ids = pa.array(np.arange(8, dtype="int64")).slice(2, 3)
    var offsets = pa.array(np.arange(8, dtype="int32")).slice(2, 3)
    var float_view = floats.to_numpy(zero_copy_only=True)
    assert_false(Bool(py=float_view.flags.writeable))
    _check_typed_borrow[DType.float32](float_view, Int(py=floats.buffers()[1].address) + 8)
    _check_typed_borrow[DType.int64](ids.to_numpy(zero_copy_only=True), Int(py=ids.buffers()[1].address) + 16)
    _check_typed_borrow[DType.int32](offsets.to_numpy(zero_copy_only=True), Int(py=offsets.buffers()[1].address) + 8)
    with assert_raises():
        _ = from_numpy_array[DType.float32](float_view)
    with assert_raises():
        _check_typed_borrow[DType.int64](float_view, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
