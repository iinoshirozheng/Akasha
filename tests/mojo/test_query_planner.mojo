from akasha.query.planner import QueryPlanner
from std.testing import assert_equal, TestSuite


def test_planner_uses_exact_for_small_collections() raises:
    var plan = QueryPlanner.plan_dense(63, 63, 10, 16, 128, False, True, True)
    assert_equal(plan.use_hnsw, False)
    assert_equal(plan.initial_ef, 16)
    assert_equal(plan.max_ef, 128)
    assert_equal(plan.reason, "small_collection")


def test_planner_rejects_metric_mismatch() raises:
    var plan = QueryPlanner.plan_dense(
        1_000, 1_000, 10, 32, 128, False, False, True
    )
    assert_equal(plan.use_hnsw, False)
    assert_equal(plan.reason, "metric_mismatch")


def test_planner_rejects_unavailable_graph() raises:
    var plan = QueryPlanner.plan_dense(
        1_000, 1_000, 10, 32, 128, False, True, False
    )
    assert_equal(plan.use_hnsw, False)
    assert_equal(plan.reason, "graph_unavailable")


def test_planner_uses_exact_for_small_filter_cardinality() raises:
    var plan = QueryPlanner.plan_dense(1_000, 20, 10, 16, 128, True, True, True)
    assert_equal(plan.use_hnsw, False)
    assert_equal(plan.reason, "selectivity")


def test_planner_uses_exact_for_highly_selective_filter() raises:
    var plan = QueryPlanner.plan_dense(
        1_000, 100, 10, 16, 128, True, True, True
    )
    assert_equal(plan.use_hnsw, False)
    assert_equal(plan.reason, "selectivity")


def test_planner_uses_hnsw_for_normal_ann_and_normalizes_ef() raises:
    var unfiltered = QueryPlanner.plan_dense(
        64, 64, 10, 4, 128, False, True, True
    )
    assert_equal(unfiltered.use_hnsw, True)
    assert_equal(unfiltered.initial_ef, 10)
    assert_equal(unfiltered.max_ef, 128)
    assert_equal(unfiltered.reason, "ann")

    var filtered = QueryPlanner.plan_dense(
        1_000, 200, 10, 200, 128, True, True, True
    )
    assert_equal(filtered.use_hnsw, True)
    assert_equal(filtered.initial_ef, 128)
    assert_equal(filtered.max_ef, 128)
    assert_equal(filtered.reason, "ann")


def test_planner_rejects_invalid_counts_and_ef_limits() raises:
    var invalid_count = QueryPlanner.plan_dense(
        -1, 0, 10, 16, 128, False, True, True
    )
    assert_equal(invalid_count.use_hnsw, False)
    assert_equal(invalid_count.reason, "invalid_request")

    var impossible_ef = QueryPlanner.plan_dense(
        1_000, 1_000, 10, 8, 9, False, True, True
    )
    assert_equal(impossible_ef.use_hnsw, False)
    assert_equal(impossible_ef.reason, "ef_limit_below_k")


def test_compatibility_wrapper_preserves_boolean_policy() raises:
    assert_equal(QueryPlanner.use_hnsw(63, 10, 63, False), False)
    assert_equal(QueryPlanner.use_hnsw(64, 10, 64, False), True)
    assert_equal(QueryPlanner.use_hnsw(1_000, 10, 20, True), False)
    assert_equal(QueryPlanner.use_hnsw(1_000, 10, 100, True), False)
    assert_equal(QueryPlanner.use_hnsw(1_000, 10, 200, True), True)
    assert_equal(QueryPlanner.use_hnsw(-1, 10, 0, False), False)
    assert_equal(QueryPlanner.use_hnsw(100, 0, 100, False), False)
    assert_equal(QueryPlanner.use_hnsw(100, 10, 101, True), False)


def test_cardinality_dispatch_does_not_depend_on_ef_cost_or_k() raises:
    # Qdrant dispatch uses available-vector/filter cardinality, not an
    # empirical graph-work estimate or a 2*k shortcut.
    for ef in [32, 512]:
        var plan = QueryPlanner.plan_dense(
            8192, 8192, 10, ef, 1024, False, True, True,
        )
        assert_equal(plan.use_hnsw, True)
        assert_equal(plan.reason, "ann")
    var large_k = QueryPlanner.plan_dense(
        256, 40, 20, 32, 128, True, True, True,
    )
    assert_equal(large_k.use_hnsw, True)


def test_cardinality_boundary_uses_available_population() raises:
    for matched in [124, 125, 126]:
        var plan = QueryPlanner.plan_dense(
            1000, matched, 10, 32, 128, True, True, True,
        )
        assert_equal(plan.use_hnsw, matched >= 125)
    var huge = QueryPlanner.plan_dense(
        Int.MAX, Int.MAX, 10, 512, 1024, False, True, True,
    )
    assert_equal(huge.use_hnsw, True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
