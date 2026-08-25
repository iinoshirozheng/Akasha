from akasha.storage.memtable import MemTable
from std.testing import assert_equal, assert_raises, TestSuite


def test_memtable_keeps_latest_live_value_in_id_order() raises:
    var table = MemTable(2)
    table.apply_upsert(20, 1, [1.0, 0.0])
    table.apply_upsert(10, 2, [0.0, 1.0])
    table.apply_upsert(20, 3, [2.0, 0.0])

    var entries = table.live_entries()

    assert_equal(len(entries), 2)
    assert_equal(entries[0].id, 10)
    assert_equal(entries[1].id, 20)
    assert_equal(entries[1].sequence, UInt64(3))
    assert_equal(entries[1].values[0], Float32(2.0))
    assert_equal(table.last_sequence, UInt64(3))


def test_tombstone_hides_value_and_older_write_cannot_resurrect_it() raises:
    var table = MemTable(1)
    table.apply_upsert(7, 4, [4.0])
    table.apply_delete(7, 6)
    table.apply_upsert(7, 5, [5.0])

    var entries = table.live_entries()

    assert_equal(len(entries), 0)
    assert_equal(table.entry_count(), 1)
    assert_equal(table.last_sequence, UInt64(6))


def test_delete_of_missing_id_records_tombstone() raises:
    var table = MemTable(3)
    table.apply_delete(99, 8)

    assert_equal(table.entry_count(), 1)
    assert_equal(len(table.live_entries()), 0)
    assert_equal(table.last_sequence, UInt64(8))


def test_memtable_rejects_invalid_dimension_and_vector() raises:
    with assert_raises():
        _ = MemTable(0)

    var table = MemTable(2)
    with assert_raises():
        table.apply_upsert(1, 1, [1.0])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
