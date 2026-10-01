from akasha.common.config import CollectionConfig
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.storage.point_store import PointStore
from std.ffi import c_int, external_call
from std.testing import (
    assert_equal,
    assert_almost_equal,
    assert_raises,
    TestSuite,
)


def _path(suffix: String) -> String:
    return String(
        "/tmp/akasha-field-search-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
    )


def _native_case[dtype: DType](suffix: String) raises:
    var query = VectorValue.dense[dtype]([Scalar[dtype](1), Scalar[dtype](0)])
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "native", 0, query.scalar(), 1, 0, 2))
    var store = PointStore.open(_path(suffix), fields.copy())
    var mutations: List[PointMutation] = [
        PointMutation(
            10,
            1,
            [
                FieldUpdate.set(
                    2,
                    VectorValue.dense[dtype](
                        [Scalar[dtype](2), Scalar[dtype](0)]
                    ),
                )
            ],
        ),
        PointMutation(
            -1,
            1,
            [
                FieldUpdate.set(
                    2,
                    VectorValue.dense[dtype](
                        [Scalar[dtype](0), Scalar[dtype](0)]
                    ),
                )
            ],
        ),
        PointMutation(5, 1, []),
    ]
    _ = store.apply_batch(mutations)
    var results = store.search("native", query, 20)
    assert_equal(len(results), 2)
    assert_equal(results[0].id, -1)
    assert_equal(results[1].id, 10)
    assert_equal(results[0].score, Float64(1))
    store.flush()
    store.close()
    var reopened = PointStore.open(_path(suffix), fields^)
    var again = reopened.search("native", query, 1)
    assert_equal(len(again), 1)
    assert_equal(again[0].id, -1)
    assert_equal(
        reopened.get(10).value().field_at(0).value().scalar(), query.scalar()
    )
    reopened.close()


def test_all_native_dense_types_search_named_only_points_and_reopen() raises:
    _native_case[DType.float32]("f32")
    _native_case[DType.float16]("f16")
    _native_case[DType.bfloat16]("bf16")
    _native_case[DType.int8]("i8")
    _native_case[DType.uint8]("u8")


def test_filter_runs_before_topk_and_missing_fields_never_rank() raises:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "image", 0, 0, 0, 0, 2))
    var store = PointStore.open(_path("filter"), fields^)
    var red: List[DocumentField] = [
        DocumentField("color", PayloadValue.string("red"))
    ]
    var blue: List[DocumentField] = [
        DocumentField("color", PayloadValue.string("blue"))
    ]
    var mutations: List[PointMutation] = [
        PointMutation(
            1,
            1,
            [FieldUpdate.set(2, VectorValue.dense[DType.float32]([100, 0]))],
            Optional(blue^),
        ),
        PointMutation(
            2,
            1,
            [FieldUpdate.set(2, VectorValue.dense[DType.float32]([2, 0]))],
            Optional(red^),
        ),
        PointMutation(3, 1, []),
    ]
    _ = store.apply_batch(mutations)
    var query = VectorValue.dense[DType.float32]([1, 0])
    var filter = FilterExpression.condition(
        FilterCondition.equal("color", PayloadValue.string("red"))
    )
    var results = store.search("image", query, 1, Optional(filter^))
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 2)
    var change: List[PointMutation] = [
        PointMutation(2, 3, [FieldUpdate.remove(2)]),
        PointMutation.delete(1),
    ]
    _ = store.apply_batch(change)
    assert_equal(len(store.search("image", query, 10)), 0)
    store.close()


def test_binary_jaccard_and_maxsim_rank_with_their_own_score_direction() raises:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "bits", 3, 5, 4, 0, 9))
    fields.append(VectorFieldSpec(3, "patches", 2, 0, 0, 0, 2))
    var store = PointStore.open(_path("binary-multi"), fields.copy())
    var mutations: List[PointMutation] = [
        PointMutation(
            1,
            1,
            [
                FieldUpdate.set(
                    2, VectorValue.binary(9, [UInt8(0x0B), UInt8(1)])
                ),
                FieldUpdate.set(
                    3, VectorValue.multivector[DType.float32](2, [2, 1, -1, 3])
                ),
            ],
        ),
        PointMutation(
            2,
            1,
            [
                FieldUpdate.set(
                    2, VectorValue.binary(9, [UInt8(0x0D), UInt8(0)])
                ),
                FieldUpdate.set(
                    3, VectorValue.multivector[DType.float32](2, [1, 1])
                ),
            ],
        ),
        PointMutation(
            3,
            1,
            [FieldUpdate.set(3, VectorValue.multivector[DType.float32](2, []))],
        ),
    ]
    _ = store.apply_batch(mutations)
    store.flush()
    store.close()
    var reopened = PointStore.open(_path("binary-multi"), fields^)
    var binary = VectorValue.binary(9, [UInt8(0x0B), UInt8(1)])
    var binary_results = reopened.search("bits", binary, 10)
    assert_equal(binary_results[0].id, 1)
    assert_almost_equal(binary_results[1].score, Float64(0.6), atol=1.0e-15)
    var multi = VectorValue.multivector[DType.float32](2, [1, 0, 0, 1])
    var multi_results = reopened.search("patches", multi, 10)
    assert_equal(len(multi_results), 2)
    assert_equal(multi_results[0].id, 1)
    assert_equal(multi_results[0].score, Float64(5))
    assert_equal(multi_results[1].score, Float64(2))
    reopened.close()


def test_empty_search_still_validates_field_dtype_shape_and_k() raises:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "half", 0, 2, 1, 0, 2))
    var store = PointStore.open(_path("invalid"), fields^)
    var query = VectorValue.dense[DType.float16]([Float16(1), Float16(0)])
    with assert_raises():
        _ = store.search("missing", query, 1)
    with assert_raises():
        _ = store.search("half", query, 0)
    var wrong = VectorValue.dense[DType.float32]([1, 0])
    with assert_raises():
        _ = store.search("half", wrong, 1)
    assert_equal(len(store.search("half", query, Int.MAX)), 0)
    store.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
