from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)


def _config(dimension: Int, metric: MetricKind) -> CollectionConfig:
    var config = CollectionConfig.defaults(dimension)
    config.ann_metric = metric.copy()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 128
    config.max_level = 12
    config.level_seed = UInt64(0x123456789ABCDEF0)
    return config^


def test_config_constructor_binds_dot_and_returns_public_scores() raises:
    var index = HnswIndex(_config(2, MetricKind.dot()))
    index.add(20, [2.0, 0.0])
    index.add(10, [1.0, 0.0])
    index.add(30, [-1.0, 0.0])

    var results = index.search([1.0, 0.0], 3, ef_search=16)
    assert_equal(results[0].id, 20)
    assert_almost_equal(results[0].score, 2.0, atol=1.0e-6)
    assert_equal(results[1].id, 10)
    assert_almost_equal(results[1].score, 1.0, atol=1.0e-6)


def test_config_constructor_binds_l2_and_returns_public_scores() raises:
    var index = HnswIndex(_config(1, MetricKind.l2()))
    index.add(20, [2.0])
    index.add(10, [1.0])
    index.add(30, [-1.0])

    var results = index.search([1.25], 3, ef_search=16)
    assert_equal(results[0].id, 10)
    assert_almost_equal(results[0].score, 0.0625, atol=1.0e-6)
    assert_equal(results[1].id, 20)
    assert_almost_equal(results[1].score, 0.5625, atol=1.0e-6)


def test_config_constructor_binds_cosine_and_returns_public_scores() raises:
    var index = HnswIndex(_config(2, MetricKind.cosine()))
    index.add(30, [-1.0, 0.0])
    index.add(20, [0.0, 2.0])
    index.add(10, [4.0, 0.0])

    var results = index.search([2.0, 0.0], 3, ef_search=16)
    assert_equal(results[0].id, 10)
    assert_almost_equal(results[0].score, 1.0, atol=1.0e-5)
    assert_equal(results[1].id, 20)
    assert_almost_equal(results[1].score, 0.0, atol=1.0e-5)


def test_legacy_constructor_is_l2_only_and_rejects_metric_mismatch() raises:
    var index = HnswIndex(1, m=2, max_level=4)
    index.add(1, [1.0])
    index.add(2, [2.0])

    assert_equal(index.search_l2([1.1], 1, 8)[0].id, 1)
    var message = String()
    try:
        _ = index.search_dot([1.0], 1, 8)
    except error:
        message = String(error)
    assert_equal(
        message,
        "HNSW metric mismatch: graph is bound to l2 but search requested dot",
    )
    message = ""
    try:
        _ = index.search_cosine([1.0], 1, 8)
    except error:
        message = String(error)
    assert_equal(
        message,
        "HNSW metric mismatch: graph is bound to l2 but search requested cosine",
    )


def test_deterministic_public_id_ties_and_duplicate_rejection() raises:
    var index = HnswIndex(_config(1, MetricKind.l2()))
    index.add(20, [1.0])
    index.add(10, [-1.0])
    index.add(30, [3.0])

    var results = index.search([0.0], 2, ef_search=16)
    assert_equal(results[0].id, 10)
    assert_equal(results[1].id, 20)
    with assert_raises():
        index.add(10, [0.0])
    assert_equal(index.point_count(), 3)


def test_hnsw_validates_configuration_vectors_and_search() raises:
    with assert_raises():
        _ = HnswIndex(0)
    with assert_raises():
        _ = HnswIndex(2, m=0)

    var index = HnswIndex(2)
    with assert_raises():
        index.add(1, [1.0])
    assert_equal(index.point_count(), 0)
    assert_true(index.valid)
    assert_true(index.graph.is_valid())
    index.add(1, [1.0, 0.0])
    with assert_raises():
        _ = index.search_l2([1.0], 1, 8)
    with assert_raises():
        _ = index.search_l2([1.0, 0.0], 0, 8)
    with assert_raises():
        _ = index.search_l2([1.0, 0.0], 1, 0)


def test_empty_standard_index_is_structurally_valid() raises:
    var index = HnswIndex(_config(2, MetricKind.l2()))
    index.validate_structure()


def test_huge_k_clamps_to_actual_points_and_configured_ef_limit() raises:
    var index = HnswIndex(_config(1, MetricKind.l2()))
    for id in range(1, 5):
        index.add(id, [Float32(id)])

    var huge = index.search([2.5], Int.MAX, ef_search=1)
    assert_equal(len(huge), 4)
    assert_equal(index.last_search_effective_ef(), 4)

    var above_max = index.search([2.5], 129, ef_search=1)
    assert_equal(len(above_max), 4)
    assert_equal(index.last_search_effective_ef(), 4)

    var bounded_config = _config(1, MetricKind.l2())
    bounded_config.default_ef_search = 4
    bounded_config.max_ef_search = 4
    var bounded = HnswIndex(bounded_config)
    for id in range(1, 6):
        bounded.add(id, [Float32(id)])
    with assert_raises():
        _ = bounded.search([2.5], 5, ef_search=1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
