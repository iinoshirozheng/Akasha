from akasha.index.hnsw_entries import HnswEntry, HnswEntryPoints
from akasha.index.hnsw_core import HnswSearchAdmission
from akasha.index.hnsw_core import search_scored_allowed_with_widening_core
from akasha.index.hnsw_query_scorer import MetricPointScorer
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.common.config import MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_storage import HnswStorage
from std.testing import assert_equal, assert_false, assert_raises, TestSuite
from std.python import Python


def test_promotion_and_bounded_extra_entries() raises:
    var graph = HnswStorage(1, 2, 4)
    var entries = HnswEntryPoints(2)
    var all_points = HnswSearchAdmission()
    for level in range(4):
        var slot = graph.append(10 + level, [Float32(level)], level)
        entries.new_point(graph, slot, all_points)
    entries.validate(graph)
    assert_equal(entries.primary, [HnswEntry(UInt32(3), 3)])
    assert_equal(len(entries.extra), 2)
    assert_equal(entries.get_entry(graph, all_points).value().slot, UInt32(3))
    _ = graph.mark_deleted(13)
    assert_equal(entries.get_entry(graph, all_points).value().slot, UInt32(2))
    _ = graph.mark_deleted(12)
    assert_equal(entries.get_entry(graph, all_points).value().slot, UInt32(1))
    _ = graph.mark_deleted(11)
    assert_false(Bool(entries.get_entry(graph, all_points)))


def test_missing_eligible_primary_starts_new_component() raises:
    var graph = HnswStorage(1, 2, 4)
    var entries = HnswEntryPoints(2)
    var all_points = HnswSearchAdmission()
    var old = graph.append(10, [0.0], 2)
    entries.new_point(graph, old, all_points)
    _ = graph.mark_deleted(10)
    var new = graph.append(11, [1.0], 0)
    entries.new_point(graph, new, all_points)
    entries.validate(graph)
    assert_equal(entries.primary, [HnswEntry(old, 2), HnswEntry(new, 0)])
    assert_equal(entries.get_entry(graph, all_points).value().slot, new)


def test_custom_entries_highest_last_tie_and_fallback() raises:
    var graph = HnswStorage(1, 2, 4)
    var entries = HnswEntryPoints()
    var all_points = HnswSearchAdmission()
    for i in range(4):
        var slot = graph.append(10 + i, [Float32(i)], 2 if i < 2 else 1)
        entries.new_point(graph, slot, all_points)
    var custom: List[UInt32] = [0, 1, 2, 3]
    assert_equal(entries.get_custom_entry(graph, all_points, custom).value().slot, UInt32(1))
    custom = [1, 0, 3]
    assert_equal(entries.get_custom_entry(graph, all_points, custom).value().slot, UInt32(0))
    var filtered = HnswSearchAdmission([False, False, True, True])
    assert_equal(entries.get_custom_entry(graph, filtered, custom).value().slot, UInt32(3))
    custom = [0, 1]
    assert_equal(entries.get_custom_entry(graph, filtered, custom).value().slot,
                 entries.get_entry(graph, filtered).value().slot)
    _ = graph.mark_deleted(11)
    assert_equal(entries.get_custom_entry(graph, all_points, custom).value().slot, UInt32(0))
    with assert_raises():
        _ = entries.get_custom_entry(graph, all_points, [UInt32(99)])


def test_custom_entries_match_unedited_rust_method() raises:
    var fixture = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/qdrant-discovery/discovery.json").read())
    var samples = fixture["entries"]
    for index in range(len(samples)):
        var sample = samples[index]
        var graph = HnswStorage(1, 2, 4)
        var entries = HnswEntryPoints()
        var flags = List[Bool]()
        for i in range(len(sample["levels"])):
            var level = Int(py=sample["levels"][i])
            var slot = graph.append(10 + i, [Float32(i)], level)
            entries.primary.append(HnswEntry(slot, level))
            flags.append(Bool(py=sample["allowed"][i]))
        var allowed = HnswSearchAdmission(flags^)
        var custom = List[UInt32]()
        for i in range(len(sample["custom"])):
            custom.append(UInt32(Int(py=sample["custom"][i])))
        var actual = entries.get_custom_entry(graph, allowed, custom)
        assert_equal(Int(actual.value().slot) if actual else -1, Int(py=sample["expected"]))


def test_custom_entry_changes_traversed_component_and_resets_scratch() raises:
    var graph = HnswStorage(1, 2, 4)
    for i in range(4):
        _ = graph.append(i, [Float32(i)], 0)
    graph.set_neighbors(UInt32(0), 0, [UInt32(1)])
    graph.set_neighbors(UInt32(1), 0, [UInt32(0)])
    graph.set_neighbors(UInt32(2), 0, [UInt32(3)])
    graph.set_neighbors(UInt32(3), 0, [UInt32(2)])
    var entries = HnswEntryPoints()
    entries.primary.append(HnswEntry(UInt32(0), 0))
    var scorer = MetricPointScorer(MetricDispatcher(MetricKind.l2(), ScalarKind.f32(), 1), [Float32(3)])
    var allowed = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    var normal = search_scored_allowed_with_widening_core(
        graph, scorer, 1, 2, 4, 4, False, False, entries, "test", allowed, scratch)
    assert_equal(normal.results[0].id, 1)
    var slots: List[UInt32] = [2]
    var custom = search_scored_allowed_with_widening_core(
        graph, scorer, 1, 2, 4, 4, False, False, entries, "test", allowed, scratch,
        custom_entries=Optional(slots^))
    assert_equal(custom.results[0].id, 3)
    var again = search_scored_allowed_with_widening_core(
        graph, scorer, 1, 2, 4, 4, False, False, entries, "test", allowed, scratch)
    assert_equal(again.results[0].id, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
