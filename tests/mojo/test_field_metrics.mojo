from akasha.compute.field_metrics import (
    score_vector_field,
    validate_field_query,
)
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from std.math import isfinite
from std.testing import (
    assert_equal,
    assert_almost_equal,
    assert_raises,
    assert_true,
    TestSuite,
)


def _dense_cases[dtype: DType]() raises:
    var query = VectorValue.dense[dtype](
        [Scalar[dtype](1), Scalar[dtype](2), Scalar[dtype](-3)]
    )
    var candidate = VectorValue.dense[dtype](
        [Scalar[dtype](3), Scalar[dtype](-2), Scalar[dtype](4)]
    )
    var expected: List[Float64] = [-13, 69, -0.6451791670811046]
    for metric in range(3):
        var field = VectorFieldSpec(
            2, "v", 0, query.scalar(), UInt8(metric), 0, 3
        )
        assert_almost_equal(
            score_vector_field(query, candidate, field),
            expected[metric],
            atol=1.0e-12,
        )


def test_float_dense_metrics_match_independent_numeric_goldens() raises:
    _dense_cases[DType.float32]()
    _dense_cases[DType.float16]()
    _dense_cases[DType.bfloat16]()


def test_native_integer_extremes_do_not_overflow_input_scalar_width() raises:
    var signed_a = VectorValue.dense[DType.int8]([Int8(-128), Int8(127)])
    var signed_b = VectorValue.dense[DType.int8]([Int8(127), Int8(-128)])
    var field = VectorFieldSpec(2, "v", 0, 3, 0, 0, 2)
    assert_equal(score_vector_field(signed_a, signed_b, field), Float64(-32512))
    field.metric = 1
    assert_equal(score_vector_field(signed_a, signed_b, field), Float64(130050))
    var unsigned_a = VectorValue.dense[DType.uint8]([UInt8(0), UInt8(255)])
    var unsigned_b = VectorValue.dense[DType.uint8]([UInt8(255), UInt8(0)])
    field.scalar = 4
    assert_equal(
        score_vector_field(unsigned_a, unsigned_b, field), Float64(130050)
    )


def test_finite_f32_extremes_produce_finite_float64_scores() raises:
    var values = VectorValue.dense[DType.float32](
        [Float32(3.0e38), Float32(3.0e38)]
    )
    var field = VectorFieldSpec(2, "v", 0, 0, 0, 0, 2)
    var score = score_vector_field(values, values, field)
    assert_true(isfinite(score))
    assert_true(score > Float64(1.0e77))
    field.metric = 2
    assert_almost_equal(
        score_vector_field(values, values, field), Float64(1), atol=1.0e-15
    )


def test_packed_binary_hamming_and_jaccard_include_partial_final_byte() raises:
    var a = VectorValue.binary(9, [UInt8(0x0B), UInt8(1)])
    var b = VectorValue.binary(9, [UInt8(0x0D), UInt8(0)])
    var field = VectorFieldSpec(2, "bits", 3, 5, 3, 0, 9)
    assert_equal(score_vector_field(a, b, field), Float64(3))
    field.metric = 4
    assert_almost_equal(
        score_vector_field(a, b, field), Float64(0.6), atol=1.0e-15
    )
    var zero = VectorValue.binary(9, [UInt8(0), UInt8(0)])
    assert_equal(score_vector_field(zero, zero, field), Float64(0))
    assert_equal(score_vector_field(a, zero, field), Float64(1))


def test_ragged_maxsim_sums_best_match_per_query_row() raises:
    var query = VectorValue.multivector[DType.float32](2, [1, 0, 0, 1])
    var candidate = VectorValue.multivector[DType.float32](
        2, [2, 1, -1, 3, 0, -2]
    )
    var field = VectorFieldSpec(2, "patches", 2, 0, 0, 0, 2)
    assert_equal(score_vector_field(query, candidate, field), Float64(5))
    field.metric = 1
    assert_equal(score_vector_field(query, candidate, field), Float64(6))
    field.metric = 2
    assert_almost_equal(
        score_vector_field(query, candidate, field),
        Float64(1.8431104890504297),
        atol=1.0e-12,
    )
    var empty = VectorValue.multivector[DType.float32](2, [])
    with assert_raises():
        validate_field_query(empty, field)
    with assert_raises():
        _ = score_vector_field(query, empty, field)


def test_sparse_dot_and_query_schema_validation() raises:
    var a = VectorValue.sparse([SparseElement(1, 2), SparseElement(4, -3)])
    var b = VectorValue.sparse(
        [SparseElement(1, 5), SparseElement(2, 1), SparseElement(4, 2)]
    )
    var field = VectorFieldSpec(2, "terms", 1, 0, 0, 2, 0)
    assert_equal(score_vector_field(a, b, field), Float64(4))
    var empty = VectorValue.sparse([])
    assert_equal(score_vector_field(a, empty, field), Float64(0))
    var wrong = VectorValue.dense[DType.float32]([1, 2])
    with assert_raises():
        validate_field_query(wrong, field)
    var cosine = VectorFieldSpec(2, "cos", 0, 0, 2, 0, 2)
    var zero = VectorValue.dense[DType.float32]([0, 0])
    with assert_raises():
        validate_field_query(zero, cosine)
    with assert_raises():
        _ = score_vector_field(wrong, zero, cosine)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
