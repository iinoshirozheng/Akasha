from akasha.index.hnsw_entries import HnswEntry, HnswEntryPoints
from akasha.index.hnsw_core import HnswSearchAdmission
from akasha.index.hnsw_storage import HnswStorage
from std.testing import assert_equal, assert_false, TestSuite


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
