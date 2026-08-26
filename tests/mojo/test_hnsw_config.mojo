from akasha import CollectionConfig, MetricKind, ScalarKind
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _valid_config() -> CollectionConfig:
    return CollectionConfig(
        dimension=32,
        ann_metric=MetricKind.l2(),
        scalar_kind=ScalarKind.f32(),
        m=16,
        m0=32,
        ef_construction=128,
        default_ef_search=64,
        max_ef_search=512,
        max_level=32,
        rebuild_inactive_percent=25,
        delta_max_points=10_000,
        level_seed=UInt64(0xA5A5A5A5A5A5A5A5),
    )


def _validation_error(config: CollectionConfig) -> String:
    try:
        config.validate()
    except error:
        return String(error)
    return ""


def test_metric_tags_names_and_equality_are_stable() raises:
    assert_equal(MetricKind.dot().tag(), UInt8(0))
    assert_equal(MetricKind.l2().tag(), UInt8(1))
    assert_equal(MetricKind.cosine().tag(), UInt8(2))
    assert_equal(MetricKind.dot().name(), "dot")
    assert_equal(MetricKind.l2().name(), "l2")
    assert_equal(MetricKind.cosine().name(), "cosine")
    assert_equal(MetricKind.dot(), MetricKind.dot())
    assert_true(MetricKind.dot() == MetricKind.dot())
    assert_false(MetricKind.dot() == MetricKind.l2())


def test_scalar_tags_names_and_equality_are_stable() raises:
    assert_equal(ScalarKind.f32().tag(), UInt8(0))
    assert_equal(ScalarKind.bf16().tag(), UInt8(1))
    assert_equal(ScalarKind.f16().tag(), UInt8(2))
    assert_equal(ScalarKind.i8().tag(), UInt8(3))
    assert_equal(ScalarKind.f32().name(), "f32")
    assert_equal(ScalarKind.bf16().name(), "bf16")
    assert_equal(ScalarKind.f16().name(), "f16")
    assert_equal(ScalarKind.i8().name(), "i8")
    assert_equal(ScalarKind.i8(), ScalarKind.i8())
    assert_true(ScalarKind.i8() == ScalarKind.i8())
    assert_false(ScalarKind.i8() == ScalarKind.f32())


def test_defaults_are_explicit_and_valid() raises:
    var config = CollectionConfig.defaults(32)
    config.validate()

    assert_equal(config.dimension, 32)
    assert_true(config.ann_metric == MetricKind.l2())
    assert_true(config.scalar_kind == ScalarKind.f32())
    assert_equal(config.m, 16)
    assert_equal(config.m0, 32)
    assert_equal(config.ef_construction, 128)
    assert_equal(config.default_ef_search, 64)
    assert_equal(config.max_ef_search, 512)
    assert_equal(config.max_level, 32)
    assert_equal(config.rebuild_inactive_percent, 25)
    assert_equal(config.delta_max_points, 10_000)
    assert_equal(config.level_seed, UInt64(0xA5A5A5A5A5A5A5A5))
    assert_equal(config.metric_name(), "l2")
    assert_equal(config.scalar_name(), "f32")


def test_valid_cosine_bf16_configuration() raises:
    var config = _valid_config()
    config.ann_metric = MetricKind.cosine()
    config.scalar_kind = ScalarKind.bf16()
    config.validate()
    assert_equal(config.metric_name(), "cosine")
    assert_equal(config.scalar_name(), "bf16")


def test_rejects_each_invalid_integer_boundary() raises:
    var zero_dimension = _valid_config()
    zero_dimension.dimension = 0
    with assert_raises():
        zero_dimension.validate()

    var negative_dimension = _valid_config()
    negative_dimension.dimension = -1
    with assert_raises():
        negative_dimension.validate()

    var small_m = _valid_config()
    small_m.m = 1
    with assert_raises():
        small_m.validate()

    var small_m0 = _valid_config()
    small_m0.m0 = 15
    with assert_raises():
        small_m0.validate()

    var small_construction = _valid_config()
    small_construction.ef_construction = 31
    with assert_raises():
        small_construction.validate()

    var zero_default_search = _valid_config()
    zero_default_search.default_ef_search = 0
    with assert_raises():
        zero_default_search.validate()

    var small_max_search = _valid_config()
    small_max_search.max_ef_search = 63
    with assert_raises():
        small_max_search.validate()

    var zero_max_level = _valid_config()
    zero_max_level.max_level = 0
    with assert_raises():
        zero_max_level.validate()

    var excessive_max_level = _valid_config()
    excessive_max_level.max_level = 64
    with assert_raises():
        excessive_max_level.validate()

    var zero_rebuild_percentage = _valid_config()
    zero_rebuild_percentage.rebuild_inactive_percent = 0
    with assert_raises():
        zero_rebuild_percentage.validate()

    var excessive_rebuild_percentage = _valid_config()
    excessive_rebuild_percentage.rebuild_inactive_percent = 91
    with assert_raises():
        excessive_rebuild_percentage.validate()

    var zero_delta_limit = _valid_config()
    zero_delta_limit.delta_max_points = 0
    with assert_raises():
        zero_delta_limit.validate()

    var negative_delta_limit = _valid_config()
    negative_delta_limit.delta_max_points = -1
    with assert_raises():
        negative_delta_limit.validate()


def test_accepts_inclusive_integer_boundaries() raises:
    var config = _valid_config()
    config.m = 2
    config.m0 = 2
    config.ef_construction = 2
    config.default_ef_search = 1
    config.max_ef_search = 1
    config.max_level = 1
    config.rebuild_inactive_percent = 1
    config.delta_max_points = 1
    config.validate()

    config.max_level = 63
    config.rebuild_inactive_percent = 90
    config.validate()


def test_accepts_durable_wire_integer_maxima() raises:
    var config = _valid_config()
    config.dimension = 4_294_967_295
    config.m = 65_535
    config.m0 = 65_535
    config.ef_construction = 4_294_967_295
    config.default_ef_search = 4_294_967_295
    config.max_ef_search = 4_294_967_295
    config.delta_max_points = 4_294_967_295
    config.validate()


def test_rejects_values_above_durable_wire_integer_maxima() raises:
    var dimension = _valid_config()
    dimension.dimension = 4_294_967_296
    with assert_raises():
        dimension.validate()

    var m = _valid_config()
    m.m = 65_536
    m.m0 = 65_536
    m.ef_construction = 65_536
    with assert_raises():
        m.validate()

    var m0 = _valid_config()
    m0.m0 = 65_536
    m0.ef_construction = 65_536
    with assert_raises():
        m0.validate()

    var construction = _valid_config()
    construction.ef_construction = 4_294_967_296
    with assert_raises():
        construction.validate()

    var default_search = _valid_config()
    default_search.default_ef_search = 4_294_967_296
    default_search.max_ef_search = 4_294_967_296
    with assert_raises():
        default_search.validate()

    var max_search = _valid_config()
    max_search.max_ef_search = 4_294_967_296
    with assert_raises():
        max_search.validate()

    var delta_limit = _valid_config()
    delta_limit.delta_max_points = 4_294_967_296
    with assert_raises():
        delta_limit.validate()


def test_rejects_unknown_metric_and_scalar_tags() raises:
    var unknown_metric = _valid_config()
    unknown_metric.ann_metric = MetricKind.from_tag(UInt8(99))
    assert_equal(
        _validation_error(unknown_metric),
        "ann_metric has an unknown tag: 99",
    )

    var unknown_scalar = _valid_config()
    unknown_scalar.scalar_kind = ScalarKind.from_tag(UInt8(99))
    assert_equal(
        _validation_error(unknown_scalar),
        "scalar_kind has an unknown tag: 99",
    )


def test_scalar_metric_compatibility_is_explicit() raises:
    var l2_i8 = _valid_config()
    l2_i8.scalar_kind = ScalarKind.i8()
    with assert_raises():
        l2_i8.validate()

    var dot_i8 = _valid_config()
    dot_i8.ann_metric = MetricKind.dot()
    dot_i8.scalar_kind = ScalarKind.i8()
    dot_i8.validate()

    var cosine_i8 = _valid_config()
    cosine_i8.ann_metric = MetricKind.cosine()
    cosine_i8.scalar_kind = ScalarKind.i8()
    cosine_i8.validate()

    var l2_bf16 = _valid_config()
    l2_bf16.scalar_kind = ScalarKind.bf16()
    l2_bf16.validate()

    var l2_f16 = _valid_config()
    l2_f16.scalar_kind = ScalarKind.f16()
    l2_f16.validate()

    var l2_f32 = _valid_config()
    l2_f32.scalar_kind = ScalarKind.f32()
    l2_f32.validate()

    var dot_bf16 = _valid_config()
    dot_bf16.ann_metric = MetricKind.dot()
    dot_bf16.scalar_kind = ScalarKind.bf16()
    dot_bf16.validate()

    var dot_f16 = _valid_config()
    dot_f16.ann_metric = MetricKind.dot()
    dot_f16.scalar_kind = ScalarKind.f16()
    dot_f16.validate()

    var dot_f32 = _valid_config()
    dot_f32.ann_metric = MetricKind.dot()
    dot_f32.scalar_kind = ScalarKind.f32()
    dot_f32.validate()

    var cosine_bf16 = _valid_config()
    cosine_bf16.ann_metric = MetricKind.cosine()
    cosine_bf16.scalar_kind = ScalarKind.bf16()
    cosine_bf16.validate()

    var cosine_f16 = _valid_config()
    cosine_f16.ann_metric = MetricKind.cosine()
    cosine_f16.scalar_kind = ScalarKind.f16()
    cosine_f16.validate()

    var cosine_f32 = _valid_config()
    cosine_f32.ann_metric = MetricKind.cosine()
    cosine_f32.scalar_kind = ScalarKind.f32()
    cosine_f32.validate()


def test_fingerprint_is_stable_for_equal_configs() raises:
    var first = _valid_config()
    var second = _valid_config()
    assert_equal(first, second)
    assert_equal(first.fingerprint(), second.fingerprint())
    assert_equal(first.fingerprint(), first.fingerprint())


def test_fingerprint_matches_documented_golden_vectors() raises:
    var defaults = _valid_config()
    assert_equal(defaults.fingerprint(), UInt64(0x8D41EBD1B46D20E2))

    var alternate = CollectionConfig(
        dimension=17,
        ann_metric=MetricKind.cosine(),
        scalar_kind=ScalarKind.f16(),
        m=12,
        m0=24,
        ef_construction=96,
        default_ef_search=40,
        max_ef_search=400,
        max_level=21,
        rebuild_inactive_percent=30,
        delta_max_points=7_777,
        level_seed=UInt64(0x0123456789ABCDEF),
    )
    assert_equal(alternate.fingerprint(), UInt64(0xF124E7DE2F465213))


def test_fingerprint_includes_every_immutable_field() raises:
    var baseline = _valid_config().fingerprint()

    var dimension = _valid_config()
    dimension.dimension = 33
    assert_true(dimension.fingerprint() != baseline)

    var metric = _valid_config()
    metric.ann_metric = MetricKind.cosine()
    assert_true(metric.fingerprint() != baseline)

    var scalar = _valid_config()
    scalar.scalar_kind = ScalarKind.bf16()
    assert_true(scalar.fingerprint() != baseline)

    var m = _valid_config()
    m.m = 15
    assert_true(m.fingerprint() != baseline)

    var m0 = _valid_config()
    m0.m0 = 31
    assert_true(m0.fingerprint() != baseline)

    var construction = _valid_config()
    construction.ef_construction = 127
    assert_true(construction.fingerprint() != baseline)

    var default_search = _valid_config()
    default_search.default_ef_search = 63
    assert_true(default_search.fingerprint() != baseline)

    var max_search = _valid_config()
    max_search.max_ef_search = 511
    assert_true(max_search.fingerprint() != baseline)

    var max_level = _valid_config()
    max_level.max_level = 31
    assert_true(max_level.fingerprint() != baseline)

    var rebuild_percentage = _valid_config()
    rebuild_percentage.rebuild_inactive_percent = 24
    assert_true(rebuild_percentage.fingerprint() != baseline)

    var delta_limit = _valid_config()
    delta_limit.delta_max_points = 9_999
    assert_true(delta_limit.fingerprint() != baseline)

    var seed = _valid_config()
    seed.level_seed = UInt64(0xA5A5A5A5A5A5A5A4)
    assert_true(seed.fingerprint() != baseline)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
