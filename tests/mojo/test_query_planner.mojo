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


def test_planner_uses_exact_when_filter_matches_at_most_twice_k() raises:
    var plan = QueryPlanner.plan_dense(1_000, 20, 10, 16, 128, True, True, True)
    assert_equal(plan.use_hnsw, False)
    assert_equal(plan.reason, "filtered_match_count")


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


def test_cost_plan_accounts_for_dimension_degree_metric_and_ef() raises:
    # The same bounded policy keeps real high-D cosine's low-ef ANN route,
    # while allowing scans when requested graph effort exceeds eligible work.
    var high_dot = QueryPlanner.plan_dense(
        8192, 8192, 10, 512, 1024, False, True, True,
        dimension=1536, m0=48, metric=0,
    )
    assert_equal(high_dot.reason, "scan_cost")
    assert_equal(high_dot.use_hnsw, False)
    var low_dot = QueryPlanner.plan_dense(
        8192, 8192, 10, 32, 1024, False, True, True,
        dimension=1536, m0=48, metric=0,
    )
    assert_equal(low_dot.use_hnsw, True)
    var short_dot = QueryPlanner.plan_dense(
        8192, 8192, 10, 128, 1024, False, True, True,
        dimension=128, m0=48, metric=0,
    )
    assert_equal(short_dot.reason, "scan_cost")
    var cosine = QueryPlanner.plan_dense(
        8192, 8192, 10, 512, 1024, False, True, True,
        dimension=1536, m0=48, metric=2,
    )
    assert_equal(cosine.use_hnsw, True)
    var filtered = QueryPlanner.plan_dense(
        8192, 2048, 10, 256, 1024, True, True, True,
        dimension=1536, m0=48, metric=2,
    )
    assert_equal(filtered.reason, "scan_cost")
    var sparse_graph = QueryPlanner.plan_dense(
        8192, 8192, 10, 128, 1024, False, True, True,
        dimension=128, m0=16, metric=0,
    )
    assert_equal(sparse_graph.use_hnsw, True)


def test_cost_plan_keeps_precedence_limits_and_overflow_safety() raises:
    var short = QueryPlanner.plan_dense(
        8192, 8192, 10, 1024, 1024, False, True, True,
        dimension=127, m0=48, metric=0,
    )
    assert_equal(short.use_hnsw, True)
    var unavailable = QueryPlanner.plan_dense(
        8192, 8192, 10, 512, 1024, False, True, False,
        dimension=1536, m0=48, metric=0,
    )
    assert_equal(unavailable.reason, "graph_unavailable")
    var capped = QueryPlanner.plan_dense(
        8192, 8192, 10, 1024, 32, False, True, True,
        dimension=1536, m0=48, metric=0,
    )
    assert_equal(capped.use_hnsw, True)
    var huge = QueryPlanner.plan_dense(
        Int.MAX, Int.MAX, 10, 512, 1024, False, True, True,
        dimension=Int.MAX, m0=48, metric=0,
    )
    assert_equal(huge.use_hnsw, True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
