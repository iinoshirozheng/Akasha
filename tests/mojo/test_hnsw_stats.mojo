from akasha.index import HnswBuildStats, HnswSearchStats
from std.testing import assert_equal, TestSuite


def test_search_stats_start_zeroed_and_reset_every_field() raises:
    var stats = HnswSearchStats()
    assert_equal(stats.requested_ef, 0)
    assert_equal(stats.effective_ef, 0)
    assert_equal(stats.widening_rounds, 0)
    assert_equal(stats.upper_visited, 0)
    assert_equal(stats.base_visited, 0)
    assert_equal(stats.distance_evaluations, 0)
    assert_equal(stats.retained_candidates, 0)
    assert_equal(stats.reranked_candidates, 0)
    assert_equal(stats.filtered_rejections, 0)
    assert_equal(stats.inactive_rejections, 0)
    assert_equal(stats.base_candidates, 0)
    assert_equal(stats.delta_candidates, 0)
    assert_equal(stats.backend_name, "")
    assert_equal(stats.metric_name, "")
    assert_equal(stats.scalar_name, "")
    assert_equal(stats.storage_name, "")
    assert_equal(stats.fallback_reason, "")

    stats.requested_ef = 32
    stats.effective_ef = 64
    stats.widening_rounds = 2
    stats.upper_visited = 7
    stats.base_visited = 41
    stats.distance_evaluations = 48
    stats.retained_candidates = 20
    stats.reranked_candidates = 10
    stats.filtered_rejections = 3
    stats.inactive_rejections = 4
    stats.base_candidates = 15
    stats.delta_candidates = 5
    stats.backend_name = "native"
    stats.metric_name = "l2"
    stats.scalar_name = "f32"
    stats.storage_name = "owned"
    stats.fallback_reason = "selectivity"
    stats.reset()

    assert_equal(stats.requested_ef, 0)
    assert_equal(stats.effective_ef, 0)
    assert_equal(stats.widening_rounds, 0)
    assert_equal(stats.upper_visited, 0)
    assert_equal(stats.base_visited, 0)
    assert_equal(stats.distance_evaluations, 0)
    assert_equal(stats.retained_candidates, 0)
    assert_equal(stats.reranked_candidates, 0)
    assert_equal(stats.filtered_rejections, 0)
    assert_equal(stats.inactive_rejections, 0)
    assert_equal(stats.base_candidates, 0)
    assert_equal(stats.delta_candidates, 0)
    assert_equal(stats.backend_name, "")
    assert_equal(stats.metric_name, "")
    assert_equal(stats.scalar_name, "")
    assert_equal(stats.storage_name, "")
    assert_equal(stats.fallback_reason, "")


def test_build_stats_track_active_slots_and_reset_every_field() raises:
    var stats = HnswBuildStats()
    assert_equal(stats.slot_count, 0)
    assert_equal(stats.inactive_slots, 0)
    assert_equal(stats.maximum_level, 0)
    assert_equal(stats.directed_edges, 0)
    assert_equal(stats.distance_evaluations, 0)
    assert_equal(stats.serialized_bytes, 0)
    assert_equal(stats.active_slots(), 0)

    stats.slot_count = 17
    stats.inactive_slots = 5
    stats.maximum_level = 4
    stats.directed_edges = 81
    stats.distance_evaluations = 1_024
    stats.serialized_bytes = 4_096
    assert_equal(stats.active_slots(), 12)
    stats.reset()

    assert_equal(stats.slot_count, 0)
    assert_equal(stats.inactive_slots, 0)
    assert_equal(stats.maximum_level, 0)
    assert_equal(stats.directed_edges, 0)
    assert_equal(stats.distance_evaluations, 0)
    assert_equal(stats.serialized_bytes, 0)
    assert_equal(stats.active_slots(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
