from akasha.document.vector_value import VectorValue
from akasha.document.vector_schema import VectorFieldSpec
from akasha.index.sparse import SparseElement, validate_sparse
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def _numeric[dtype: DType](tag: UInt8) raises:
    var values: List[Scalar[dtype]] = [0, 1, 2]
    var address = Int(values.unsafe_ptr())
    var value = VectorValue.dense(values^)
    assert_equal(value.kind(), UInt8(0))
    assert_equal(value.scalar(), tag)
    assert_equal(value.dimension(), 3)
    assert_equal(Int(value.dense_values[dtype]().unsafe_ptr()), address)
    value.validate(VectorFieldSpec(2, "dense", 0, tag, 0, 0, 3))
    with assert_raises():
        value.validate(VectorFieldSpec(2, "dense", 0, tag, 0, 0, 2))
    with assert_raises():
        _ = value.sparse_values()
    var flat: List[Scalar[dtype]] = [0, 1, 2, 3, 4, 5]
    var matrix_address = Int(flat.unsafe_ptr())
    var matrix = VectorValue.multivector(3, flat^)
    assert_equal(matrix.kind(), UInt8(2))
    assert_equal(matrix.row_count(), 2)
    assert_equal(matrix.scalar(), tag)
    assert_equal(
        Int(matrix.multivector_values[dtype]().unsafe_ptr()), matrix_address
    )
    matrix.validate(VectorFieldSpec(3, "multi", 2, tag, 0, 0, 3))
    var empty = VectorValue.multivector(3, List[Scalar[dtype]]())
    assert_equal(empty.row_count(), 0)
    empty.validate(VectorFieldSpec(3, "multi", 2, tag, 0, 0, 3))


def test_numeric_types_move_typed_storage_without_promoting_to_f32() raises:
    _numeric[DType.float32](0)
    _numeric[DType.bfloat16](1)
    _numeric[DType.float16](2)
    _numeric[DType.int8](3)
    _numeric[DType.uint8](4)
    var signed = VectorValue.dense[DType.int8]([-128, 127])
    assert_equal(signed.dense_values[DType.int8]()[0], Int8(-128))
    with assert_raises():
        _ = signed.dense_values[DType.uint8]()


def _nonfinite[dtype: DType]() raises:
    for bits in [UInt32(0x7F800000), UInt32(0xFF800000), UInt32(0x7FC00001)]:
        var bad = Scalar[dtype](bitcast[DType.float32](bits))
        with assert_raises():
            _ = VectorValue.dense(List[Scalar[dtype]]([bad]))
        with assert_raises():
            _ = VectorValue.multivector(1, List[Scalar[dtype]]([bad]))


def test_shape_and_finite_checks_precede_acceptance() raises:
    _nonfinite[DType.float32]()
    _nonfinite[DType.bfloat16]()
    _nonfinite[DType.float16]()
    with assert_raises():
        _ = VectorValue.dense(List[Float32]())
    for dimension in [-1, 0, 4_294_967_296]:
        with assert_raises():
            _ = VectorValue.multivector(dimension, List[Float32]())
    with assert_raises():
        _ = VectorValue.multivector[DType.float32](2, [1, 2, 3])


def test_new_sparse_empty_is_present_and_legacy_sparse_rule_is_preserved() raises:
    var empty = VectorValue.sparse(List[SparseElement]())
    assert_equal(empty.kind(), UInt8(1))
    assert_equal(len(empty.sparse_values()), 0)
    empty.validate(VectorFieldSpec(2, "sparse", 1, 0, 0, 2, 0))
    with assert_raises():
        validate_sparse(empty.sparse_values())
    var terms: List[SparseElement] = [
        SparseElement(0, -1),
        SparseElement(Int.MAX, 2),
    ]
    var address = Int(terms.unsafe_ptr())
    var value = VectorValue.sparse(terms^)
    assert_equal(Int(value.sparse_values().unsafe_ptr()), address)
    var invalids: List[List[SparseElement]] = [
        [SparseElement(-1, 1)],
        [SparseElement(1, 0)],
        [SparseElement(1, 1), SparseElement(1, 2)],
        [SparseElement(2, 1), SparseElement(1, 2)],
        [SparseElement(1, bitcast[DType.float32](UInt32(0x7F800000)))],
    ]
    for invalid in invalids:
        with assert_raises():
            _ = VectorValue.sparse(invalid.copy())


def test_binary_lsb_padding_and_bit_dimensions() raises:
    var bits: List[UInt8] = [255, 1]
    var address = Int(bits.unsafe_ptr())
    var value = VectorValue.binary(9, bits^)
    assert_equal(value.kind(), UInt8(3))
    assert_equal(value.scalar(), UInt8(5))
    assert_equal(value.dimension(), 9)
    assert_equal(Int(value.binary_values().unsafe_ptr()), address)
    value.validate(VectorFieldSpec(2, "bits", 3, 5, 3, 0, 9))
    value.validate(VectorFieldSpec(2, "bits", 3, 5, 4, 0, 9))
    with assert_raises():
        value.validate(VectorFieldSpec(2, "bits", 3, 5, 3, 0, 8))
    var invalids: List[List[UInt8]] = [
        [],
        [255],
        [255, 2],
        [255, 255],
        [255, 1, 0],
    ]
    for invalid in invalids:
        with assert_raises():
            _ = VectorValue.binary(9, invalid.copy())
    for dimension in [-1, 0, 4_294_967_296]:
        with assert_raises():
            _ = VectorValue.binary(dimension, List[UInt8]())
    _ = VectorValue.binary(8, [255])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
