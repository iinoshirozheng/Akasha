from akasha.query.planner import QueryPlanner
from std.testing import assert_equal, TestSuite


def test_planner_uses_exact_for_small_collections() raises:
    assert_equal(QueryPlanner.use_hnsw(63, 10, 63, False), False)
    assert_equal(QueryPlanner.use_hnsw(64, 10, 64, False), True)


def test_planner_uses_exact_for_selective_filters() raises:
    assert_equal(QueryPlanner.use_hnsw(1000, 10, 20, True), False)
    assert_equal(QueryPlanner.use_hnsw(1000, 10, 100, True), False)
    assert_equal(QueryPlanner.use_hnsw(1000, 10, 200, True), True)


def test_planner_rejects_invalid_counts() raises:
    assert_equal(QueryPlanner.use_hnsw(-1, 10, 0, False), False)
    assert_equal(QueryPlanner.use_hnsw(100, 0, 100, False), False)
    assert_equal(QueryPlanner.use_hnsw(100, 10, 101, True), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
