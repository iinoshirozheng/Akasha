from akasha.common.config import MetricKind, ScalarKind
from akasha.compute import MetricDispatcher
from std.math import inf, nan
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    TestSuite,
)


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
    assert_equal(compact.backend_name(), "unimplemented")


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
        dispatcher.canonical_prepared_unchecked(prepared_lhs, prepared_rhs),
        0.2,
        atol=1.0e-6,
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


def test_compact_scalar_backends_are_representable_but_not_executable() raises:
    var values: List[Float32] = [1.0, 0.0]
    var bf16 = MetricDispatcher(MetricKind.cosine(), ScalarKind.bf16(), 2)
    var f16 = MetricDispatcher(MetricKind.dot(), ScalarKind.f16(), 2)
    var i8 = MetricDispatcher(MetricKind.dot(), ScalarKind.i8(), 2)

    assert_equal(bf16.scalar_name(), "bf16")
    assert_almost_equal(bf16.public_score(0.25), 0.75, atol=1.0e-6)
    with assert_raises():
        _ = bf16.prepare_query(values)
    with assert_raises():
        _ = f16.canonical(values, values)
    with assert_raises():
        _ = i8.canonical_prepared_unchecked(values, values)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
