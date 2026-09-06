from akasha.common.config import (
    I8_MAX_SAFE_DIMENSION,
    MetricKind,
    ScalarKind,
)
from akasha.compute import MetricDispatcher
from std.math import inf, isfinite, nan
from std.sys import simd_width_of
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)
from std.utils.numerics import nextafter


def _unchecked_without_raises(
    dispatcher: MetricDispatcher,
    lhs: List[Float32],
    rhs: List[Float32],
) -> Float32:
    """Compile-time proof that the prepared hot path is non-raising."""
    return dispatcher._canonical_prepared_unchecked(lhs, rhs)


def test_canonical_distance_is_lower_better_for_every_metric() raises:
    var lhs: List[Float32] = [1.0, 2.0]
    var rhs: List[Float32] = [4.0, 6.0]

    var l2 = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    assert_almost_equal(l2.canonical(lhs, rhs), 25.0, atol=1.0e-6)

    var dot = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 2)
    assert_almost_equal(dot.canonical(lhs, rhs), -16.0, atol=1.0e-6)

    var cosine = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 2)
    assert_almost_equal(
        cosine.canonical(lhs, rhs),
        1.0 - 16.0 / 16.124515497,
        atol=1.0e-6,
    )


def test_negative_dot_and_dimension_one_semantics() raises:
    var dispatcher = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 1)
    var lhs: List[Float32] = [-2.0]
    var rhs: List[Float32] = [3.0]

    assert_almost_equal(dispatcher.canonical(lhs, rhs), 6.0, atol=1.0e-6)
    assert_almost_equal(dispatcher.public_score(6.0), -6.0, atol=1.0e-6)


def test_public_score_inverts_canonical_transform() raises:
    var l2 = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var dot = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 2)
    var cosine = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 2)

    assert_almost_equal(l2.public_score(4.5), 4.5, atol=1.0e-6)
    assert_almost_equal(dot.public_score(-7.5), 7.5, atol=1.0e-6)
    assert_almost_equal(cosine.public_score(0.25), 0.75, atol=1.0e-6)


def test_dispatcher_names_are_stable() raises:
    var dot = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 3)
    assert_equal(dot.metric_name(), "dot")
    assert_equal(dot.scalar_name(), "f32")
    assert_equal(dot.backend_name(), "simd-f32")

    var compact = MetricDispatcher(MetricKind.cosine(), ScalarKind.bf16(), 3)
    assert_equal(compact.metric_name(), "cosine")
    assert_equal(compact.scalar_name(), "bf16")
    assert_equal(compact.backend_name(), "scalar-bf16-f32accum")


def test_constructor_rejects_invalid_dimension_tags_and_compatibility() raises:
    with assert_raises():
        _ = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 0)
    with assert_raises():
        _ = MetricDispatcher(
            MetricKind.from_tag(UInt8(99)), ScalarKind.f32(), 2
        )
    with assert_raises():
        _ = MetricDispatcher(MetricKind.l2(), ScalarKind.from_tag(UInt8(99)), 2)
    with assert_raises():
        _ = MetricDispatcher(MetricKind.l2(), ScalarKind.i8(), 2)


def test_boundary_validation_rejects_wrong_dimension_and_nonfinite() raises:
    var dispatcher = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 2)
    var too_short: List[Float32] = [1.0]
    var finite: List[Float32] = [1.0, 2.0]
    var has_nan: List[Float32] = [1.0, nan[DType.float32]()]
    var has_inf: List[Float32] = [1.0, inf[DType.float32]()]

    with assert_raises():
        dispatcher.validate_query(too_short)
    with assert_raises():
        dispatcher.validate_vector(has_nan)
    with assert_raises():
        _ = dispatcher.canonical(has_inf, finite)


def test_dot_and_l2_preparation_returns_owned_clones() raises:
    var source: List[Float32] = [3.0, 4.0]
    var dot = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 2)
    var dot_prepared = dot.prepare_query(source)
    var l2 = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var l2_prepared = l2.prepare_graph_vector(source)

    source[0] = 99.0
    assert_almost_equal(dot_prepared[0], 3.0, atol=1.0e-6)
    assert_almost_equal(dot_prepared[1], 4.0, atol=1.0e-6)
    assert_almost_equal(l2_prepared[0], 3.0, atol=1.0e-6)
    assert_almost_equal(l2_prepared[1], 4.0, atol=1.0e-6)


def test_cosine_preparation_normalizes_once_for_prepared_hot_path() raises:
    var dispatcher = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 2)
    var lhs: List[Float32] = [3.0, 4.0]
    var rhs: List[Float32] = [0.0, 5.0]
    var prepared_lhs = dispatcher.prepare_query(lhs)
    var prepared_rhs = dispatcher.prepare_graph_vector(rhs)

    assert_almost_equal(prepared_lhs[0], 0.6, atol=1.0e-6)
    assert_almost_equal(prepared_lhs[1], 0.8, atol=1.0e-6)
    assert_almost_equal(
        prepared_lhs[0] * prepared_lhs[0] + prepared_lhs[1] * prepared_lhs[1],
        1.0,
        atol=1.0e-6,
    )
    assert_almost_equal(
        _unchecked_without_raises(dispatcher, prepared_lhs, prepared_rhs),
        0.2,
        atol=1.0e-6,
    )


def test_cosine_handles_large_and_tiny_nonzero_vectors() raises:
    var dispatcher = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 1)
    var large: List[Float32] = [1.0e15]
    var tiny: List[Float32] = [1.0e-30]

    var large_prepared = dispatcher.prepare_query(large)
    var tiny_prepared = dispatcher.prepare_graph_vector(tiny)
    var large_raw_distance = dispatcher.canonical(large, large)
    var tiny_raw_distance = dispatcher.canonical(tiny, tiny)

    assert_almost_equal(large_raw_distance, 0.0, atol=1.0e-6)
    assert_almost_equal(tiny_raw_distance, 0.0, atol=1.0e-6)
    assert_almost_equal(large_prepared[0], 1.0, atol=1.0e-6)
    assert_almost_equal(tiny_prepared[0], 1.0, atol=1.0e-6)
    assert_almost_equal(
        dispatcher.canonical_prepared(large_prepared, large_prepared),
        large_raw_distance,
        atol=1.0e-6,
    )
    assert_almost_equal(
        dispatcher.canonical_prepared(tiny_prepared, tiny_prepared),
        tiny_raw_distance,
        atol=1.0e-6,
    )


def test_cosine_mixed_magnitudes_preserve_raw_prepared_parity() raises:
    var dispatcher = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 3)
    var lhs: List[Float32] = [1.0e15, 1.0e15, 1.0]
    var rhs: List[Float32] = [1.0e15, -1.0e15, 2.0]
    var prepared_lhs = dispatcher.prepare_query(lhs)
    var prepared_rhs = dispatcher.prepare_graph_vector(rhs)
    var raw_distance = dispatcher.canonical(lhs, rhs)
    var prepared_distance = dispatcher.canonical_prepared(
        prepared_lhs, prepared_rhs
    )

    assert_true(isfinite(raw_distance))
    assert_true(isfinite(prepared_distance))
    assert_almost_equal(raw_distance, 1.0, atol=1.0e-6)
    assert_almost_equal(prepared_distance, raw_distance, atol=1.0e-5)


def test_cosine_distance_is_clamped_to_closed_range() raises:
    var dispatcher = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 2)
    var slightly_long: List[Float32] = [1.00001, 0.0]
    var opposite: List[Float32] = [-1.00001, 0.0]

    var lower = dispatcher.canonical_prepared(slightly_long, slightly_long)
    var upper = dispatcher.canonical_prepared(slightly_long, opposite)
    assert_equal(lower, 0.0)
    assert_equal(upper, 2.0)
    assert_true(lower >= 0.0 and lower <= 2.0)
    assert_true(upper >= 0.0 and upper <= 2.0)


def test_unchecked_prepared_matches_checked_for_every_f32_metric() raises:
    var raw_lhs: List[Float32] = [3.0, 4.0]
    var raw_rhs: List[Float32] = [-4.0, 3.0]

    var l2 = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 2)
    var l2_lhs = l2.prepare_query(raw_lhs)
    var l2_rhs = l2.prepare_graph_vector(raw_rhs)
    assert_almost_equal(
        _unchecked_without_raises(l2, l2_lhs, l2_rhs),
        l2.canonical_prepared(l2_lhs, l2_rhs),
        atol=1.0e-6,
    )

    var dot = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 2)
    var dot_lhs = dot.prepare_query(raw_lhs)
    var dot_rhs = dot.prepare_graph_vector(raw_rhs)
    assert_almost_equal(
        _unchecked_without_raises(dot, dot_lhs, dot_rhs),
        dot.canonical_prepared(dot_lhs, dot_rhs),
        atol=1.0e-6,
    )

    var cosine = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 2)
    var cosine_lhs = cosine.prepare_query(raw_lhs)
    var cosine_rhs = cosine.prepare_graph_vector(raw_rhs)
    assert_almost_equal(
        _unchecked_without_raises(cosine, cosine_lhs, cosine_rhs),
        cosine.canonical_prepared(cosine_lhs, cosine_rhs),
        atol=1.0e-6,
    )


def test_checked_prepared_rejects_mismatch_before_simd_load() raises:
    var width = simd_width_of[DType.float32]()
    var dispatcher = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), width)
    var lhs = List[Float32](capacity=width)
    var rhs = List[Float32](capacity=width - 1)
    for i in range(width):
        lhs.append(Float32(i))
        if i + 1 < width:
            rhs.append(Float32(i))

    with assert_raises():
        _ = dispatcher.canonical_prepared(lhs, rhs)


def test_checked_prepared_rejects_nonfinite_and_nonunit_cosine() raises:
    var dispatcher = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 2)
    var unit: List[Float32] = [1.0, 0.0]
    var nonfinite: List[Float32] = [inf[DType.float32](), 0.0]
    var not_unit: List[Float32] = [2.0, 0.0]

    with assert_raises():
        _ = dispatcher.canonical_prepared(unit, nonfinite)
    with assert_raises():
        _ = dispatcher.canonical_prepared(unit, not_unit)


def test_dot_and_l2_reject_values_that_can_overflow_f32_accumulation() raises:
    var dot = MetricDispatcher(MetricKind.dot(), ScalarKind.f32(), 1)
    var l2 = MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 1)
    var extreme: List[Float32] = [1.0e20]
    var maximum: List[Float32] = [3.0e38]
    var negative_extreme: List[Float32] = [-1.0e20]

    with assert_raises():
        _ = dot.prepare_query(extreme)
    with assert_raises():
        _ = dot.canonical(maximum, maximum)
    with assert_raises():
        _ = l2.prepare_graph_vector(negative_extreme)
    with assert_raises():
        _ = l2.canonical(extreme, negative_extreme)


def test_prepared_hot_path_is_finite_at_exact_and_multiple_simd_widths() raises:
    var width = simd_width_of[DType.float32]()
    for dimension in [width, width * 2]:
        var lhs = List[Float32](capacity=dimension)
        var rhs = List[Float32](capacity=dimension)
        for i in range(dimension):
            lhs.append(Float32((i % 5) - 2))
            rhs.append(Float32((i % 3) - 1))

        var dot = MetricDispatcher(
            MetricKind.dot(), ScalarKind.f32(), dimension
        )
        var prepared_lhs = dot.prepare_query(lhs)
        var prepared_rhs = dot.prepare_graph_vector(rhs)
        var distance = _unchecked_without_raises(
            dot, prepared_lhs, prepared_rhs
        )
        assert_true(isfinite(distance))
        assert_almost_equal(
            distance,
            dot.canonical_prepared(prepared_lhs, prepared_rhs),
            atol=1.0e-5,
        )


def test_cosine_rejects_zero_norm_at_every_checked_boundary() raises:
    var dispatcher = MetricDispatcher(MetricKind.cosine(), ScalarKind.f32(), 2)
    var zero: List[Float32] = [0.0, 0.0]
    var unit: List[Float32] = [1.0, 0.0]

    with assert_raises():
        dispatcher.validate_query(zero)
    with assert_raises():
        _ = dispatcher.prepare_graph_vector(zero)
    with assert_raises():
        _ = dispatcher.canonical(zero, unit)


def test_compact_scalar_backends_prepare_and_accumulate_in_f32() raises:
    var values: List[Float32] = [1.0, 0.0]
    var bf16 = MetricDispatcher(MetricKind.cosine(), ScalarKind.bf16(), 2)
    var f16 = MetricDispatcher(MetricKind.dot(), ScalarKind.f16(), 2)
    var i8 = MetricDispatcher(MetricKind.dot(), ScalarKind.i8(), 2)

    assert_equal(bf16.scalar_name(), "bf16")
    assert_almost_equal(bf16.public_score(0.25), 0.75, atol=1.0e-6)
    var bf16_query = bf16.prepare_query(values)
    var f16_distance = f16.canonical(values, values)
    var i8_lhs = i8.prepare_query(values)
    var i8_rhs = i8.prepare_graph_vector(values)
    assert_equal(len(bf16_query), 2)
    assert_almost_equal(f16_distance, -1.0, atol=1.0e-6)
    assert_almost_equal(i8.canonical_prepared(i8_lhs, i8_rhs), -1.0, atol=1.0e-6)
    bf16.require_supported_backend()
    f16.require_supported_backend()
    i8.require_supported_backend()


def test_i8_prepared_contract_rejects_invalid_scale_and_zero_cosine_code() raises:
    var dot = MetricDispatcher(MetricKind.dot(), ScalarKind.i8(), 2)
    var cosine = MetricDispatcher(MetricKind.cosine(), ScalarKind.i8(), 2)
    with assert_raises():
        dot.validate_prepared_vector([1.0, 0.0, 0.0])
    with assert_raises():
        cosine.validate_prepared_vector([127.0, 0.0, 0.5])
    with assert_raises():
        cosine.validate_prepared_vector([0.0, 0.0, Float32(1.0 / 127.0)])


def test_i8_dispatcher_enforces_accumulator_dimension_at_public_boundary() raises:
    with assert_raises():
        _ = MetricDispatcher(
            MetricKind.dot(),
            ScalarKind.i8(),
            I8_MAX_SAFE_DIMENSION + 1,
        )

    var boundary = MetricDispatcher(
        MetricKind.dot(), ScalarKind.i8(), I8_MAX_SAFE_DIMENSION
    )
    var zeros = List[Float32](
        length=I8_MAX_SAFE_DIMENSION, fill=Float32(0.0)
    )
    var prepared = boundary.prepare_query(zeros^)
    assert_equal(len(prepared), I8_MAX_SAFE_DIMENSION + 1)
    assert_equal(
        boundary.canonical_prepared(prepared.copy(), prepared^), Float32(0.0)
    )


def test_i8_prepared_dot_rejects_unsafe_decoded_component_magnitude() raises:
    var dispatcher = MetricDispatcher(MetricKind.dot(), ScalarKind.i8(), 2)
    with assert_raises():
        dispatcher.validate_prepared_vector(
            [127.0, 0.0, Float32.MAX_FINITE]
        )


def test_i8_cosine_preserves_nonzero_high_dimension_ties_deterministically(
) raises:
    var dimension = 65_536
    var smallest = nextafter(Float32(0.0), Float32(1.0))
    var dispatcher = MetricDispatcher(
        MetricKind.cosine(), ScalarKind.i8(), dimension
    )
    var positive = List[Float32](length=dimension, fill=smallest)
    var positive_codes = dispatcher.prepare_query(positive^)
    assert_equal(positive_codes[0], Float32(1.0))
    for index in range(1, dimension):
        assert_equal(positive_codes[index], Float32(0.0))

    var first_negative = List[Float32](length=dimension, fill=smallest)
    first_negative[0] = -smallest
    var negative_codes = dispatcher.prepare_graph_vector(first_negative^)
    assert_equal(negative_codes[0], Float32(-1.0))
    for index in range(1, dimension):
        assert_equal(negative_codes[index], Float32(0.0))
    var distance = dispatcher.canonical_prepared(
        positive_codes, negative_codes
    )
    assert_true(isfinite(distance))
    assert_true(isfinite(dispatcher.public_score(distance)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
