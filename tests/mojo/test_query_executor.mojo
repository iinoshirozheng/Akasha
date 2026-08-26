from akasha.index.bitmap import Bitmap
from akasha.query.executor import candidate_entries
from akasha.storage.memtable import MemTable
from std.testing import assert_equal, assert_raises, TestSuite


def test_candidate_executor_reads_only_selected_live_slots() raises:
    var table = MemTable(1)
    table.apply_upsert(10, 1, [1.0])
    table.apply_upsert(20, 2, [2.0])
    table.apply_delete(10, 3)
    table.apply_upsert(30, 4, [3.0])
    var candidates = Bitmap(3)
    candidates.set(1)
    candidates.set(2)

    var entries = candidate_entries(table, candidates)
    assert_equal(len(entries), 2)
    assert_equal(entries[0].id, 20)
    assert_equal(entries[1].id, 30)


def test_candidate_executor_validates_slot_alignment() raises:
    var table = MemTable(1)
    table.apply_upsert(1, 1, [1.0])
    with assert_raises():
        _ = candidate_entries(table, Bitmap(2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
