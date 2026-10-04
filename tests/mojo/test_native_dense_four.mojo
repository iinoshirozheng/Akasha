from akasha.compute.field_metrics import _score_four_validated_dense, _score_validated_field
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_raises


def check[dtype: DType]() raises:
    var audits = 0
    for dimension in [1, 2, 3, 4, 7, 15, 16, 17, 63, 127, 128, 129, 1536, 1537]:
        for seed in range(64):
            var values = List[Scalar[dtype]]()
            for column in range(dimension):
                var value = (column * 13 + seed * 7 + 5) % 251 + 1
                comptime if dtype == DType.uint8:
                    values.append(Scalar[dtype](value))
                elif dtype == DType.int8:
                    values.append(Scalar[dtype](value % 255 - 127))
                else:
                    values.append(Scalar[dtype](Float32(value - 127) / 19))
            var query = VectorValue.dense[dtype](values^)
            var rows = List[VectorValue]()
            for lane in range(4):
                var row = List[Scalar[dtype]]()
                for column in range(dimension):
                    var value = (column * 17 + seed * 11 + lane * 47 + 3) % 251 + 1
                    comptime if dtype == DType.uint8:
                        row.append(Scalar[dtype](value))
                    elif dtype == DType.int8:
                        row.append(Scalar[dtype](value % 255 - 127))
                    else:
                        row.append(Scalar[dtype](Float32(value - 127) / 23))
                rows.append(VectorValue.dense[dtype](row^))
            for metric in range(3):
                var field = VectorFieldSpec(2, "v", 0, query.scalar(), UInt8(metric), 0, dimension)
                # A one-component zero has the established cosine error.
                var failed = False
                var expected = List[Float64]()
                try:
                    for lane in range(4):
                        expected.append(_score_validated_field(query, rows[lane], field))
                except error:
                    assert_equal(String(error), "cosine similarity requires non-zero vectors")
                    failed = True
                if failed:
                    with assert_raises(contains="non-zero"):
                        _ = _score_four_validated_dense(query, rows[0], rows[1], rows[2], rows[3], field)
                    continue
                var actual = _score_four_validated_dense(query, rows[0], rows[1], rows[2], rows[3], field)
                for lane in range(4):
                    if bitcast[DType.uint64](actual[lane]) != bitcast[DType.uint64](expected[lane]):
                        print("BIT_MISMATCH", dtype, dimension, seed, metric, lane, actual[lane], expected[lane])
                    assert_equal(bitcast[DType.uint64](actual[lane]), bitcast[DType.uint64](expected[lane]))
                    audits += 1
    assert_equal(audits, 10752 if dtype == DType.uint8 else 10744)
    print("NATIVE_BITS", dtype, audits)


def test_all_scalar_metric_pairs_preserve_component_order_bits() raises:
    check[DType.float32]()
    check[DType.float16]()
    check[DType.bfloat16]()
    check[DType.int8]()
    check[DType.uint8]()


def test_finite_extremes_cancellation_and_signed_zero_keep_bits() raises:
    var rows = List[VectorValue]()
    rows.append(VectorValue.dense[DType.float32]([3.0e38, 1, -3.0e38, -0.0, 1.0e-38, 7, -7]))
    rows.append(VectorValue.dense[DType.float32]([1, -0.0, 1, 0.0, 2, 3, 5]))
    rows.append(VectorValue.dense[DType.float32]([-1.0e-38, -2, 3, -0.0, -3.0e38, 9, 8]))
    rows.append(VectorValue.dense[DType.float32]([0, 4, -2, 0, 2.0e-38, 6, 1]))
    for query_index in range(4):
        for metric in range(3):
            var field = VectorFieldSpec(2, "v", 0, 0, UInt8(metric), 0, 7)
            var actual = _score_four_validated_dense(rows[query_index], rows[0], rows[1], rows[2], rows[3], field)
            for lane in range(4):
                var expected = _score_validated_field(rows[query_index], rows[lane], field)
                assert_equal(bitcast[DType.uint64](actual[lane]), bitcast[DType.uint64](expected))


def test_every_lane_dimension_and_zero_cosine_are_checked() raises:
    var query = VectorValue.dense[DType.float32]([1, 2, 3])
    for lane in range(4):
        for bad_size in [1, 2, 4]:
            var rows = List[VectorValue]()
            for other in range(4):
                var values = List[Float32](length=bad_size if lane == other else 3, fill=1)
                rows.append(VectorValue.dense[DType.float32](values^))
            var field = VectorFieldSpec(2, "v", 0, 0, 0, 0, 3)
            with assert_raises(contains="dimension mismatch"):
                _ = _score_four_validated_dense(query, rows[0], rows[1], rows[2], rows[3], field)
        var rows = List[VectorValue]()
        for other in range(4):
            var values = List[Float32](length=3, fill=Float32(0 if lane == other else 1))
            rows.append(VectorValue.dense[DType.float32](values^))
        var field = VectorFieldSpec(2, "v", 0, 0, 2, 0, 3)
        with assert_raises(contains="non-zero"):
            _ = _score_four_validated_dense(query, rows[0], rows[1], rows[2], rows[3], field)
    var field = VectorFieldSpec(2, "v", 0, 0, 2, 0, 3)
    var zero = VectorValue.dense[DType.float32]([0, 0, 0])
    with assert_raises(contains="non-zero"):
        _ = _score_four_validated_dense(zero, query, query, query, query, field)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
