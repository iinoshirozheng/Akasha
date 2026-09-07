from akasha.document import DocumentField, PayloadValue
from akasha.storage.memtable import MemTable, MemTableEntry
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


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


def test_document_upsert_replaces_payload_and_get_returns_owned_copy() raises:
    var table = MemTable(2)
    var first_fields = List[DocumentField]()
    first_fields.append(DocumentField("chunk", PayloadValue.string("first")))
    table.apply_document_upsert(7, 1, [1.0, 0.0], first_fields^)

    var first = table.get(7)
    assert_true(Bool(first))
    assert_equal(first.value().get_field("chunk").value().as_string(), "first")
    var owned = first.value().clone()
    owned.vector[0] = 9.0
    owned.fields[0].name = "changed"

    var unchanged = table.get(7)
    assert_equal(unchanged.value().vector[0], Float32(1.0))
    assert_equal(unchanged.value().fields[0].name, "chunk")

    var second_fields = List[DocumentField]()
    second_fields.append(DocumentField("page", PayloadValue.integer(2)))
    table.apply_document_upsert(7, 2, [0.0, 1.0], second_fields^)
    var replaced = table.get(7)
    assert_false(Bool(replaced.value().get_field("chunk")))
    assert_equal(replaced.value().get_field("page").value().as_int(), Int64(2))


def test_vector_upsert_clears_payload_and_delete_hides_get() raises:
    var table = MemTable(1)
    var fields = List[DocumentField]()
    fields.append(DocumentField("source", PayloadValue.string("image")))
    table.apply_document_upsert(9, 3, [1.0], fields^)

    table.apply_upsert(9, 4, [2.0])
    var vector_only = table.get(9)
    assert_true(Bool(vector_only))
    assert_equal(len(vector_only.value().fields), 0)

    table.apply_delete(9, 5)
    assert_false(Bool(table.get(9)))


def test_older_document_write_cannot_restore_deleted_payload() raises:
    var table = MemTable(1)
    table.apply_delete(5, 10)
    var fields = List[DocumentField]()
    fields.append(DocumentField("stale", PayloadValue.boolean(True)))
    table.apply_document_upsert(5, 9, [1.0], fields^)

    assert_false(Bool(table.get(5)))


def test_memtable_slots_are_stable_and_include_tombstones() raises:
    var table = MemTable(1)
    table.apply_upsert(20, 1, [1.0])
    table.apply_upsert(10, 2, [2.0])
    table.apply_delete(20, 3)
    table.apply_upsert(30, 4, [3.0])

    assert_equal(table.slot_count(), 3)
    assert_equal(table.entry_at(0).id, 20)
    assert_true(table.entry_at(0).tombstone)
    assert_equal(table.entry_at(1).id, 10)
    assert_false(table.entry_at(1).tombstone)
    assert_equal(table.entry_at(2).id, 30)


def test_memtable_entries_after_returns_changed_latest_states_in_id_order() raises:
    var table = MemTable(1)
    table.apply_upsert(20, 1, [1.0])
    table.apply_upsert(10, 2, [2.0])
    table.apply_delete(20, 3)
    table.apply_upsert(30, 4, [3.0])

    var changed = table.entries_after(2)

    assert_equal(len(changed), 2)
    assert_equal(changed[0].id, 20)
    assert_equal(changed[0].sequence, UInt64(3))
    assert_true(changed[0].tombstone)
    assert_equal(changed[1].id, 30)
    assert_equal(changed[1].values[0], Float32(3.0))
    assert_equal(len(table.entries_after(4)), 0)


def test_memtable_entries_after_allows_global_checkpoint_beyond_dense_state() raises:
    var table = MemTable(1)
    table.apply_upsert(1, 1, [1.0])

    assert_equal(len(table.entries_after(2)), 0)


def test_memtable_linearly_merges_ordered_recovered_segments() raises:
    var table = MemTable(1)
    var base = List[MemTableEntry]()
    base.append(MemTableEntry(1, 1, False, [1.0]))
    base.append(MemTableEntry(3, 3, False, [3.0]))
    table.apply_recovered_entries(base)

    var delta = List[MemTableEntry]()
    delta.append(MemTableEntry(1, 4, True, List[Float32]()))
    delta.append(MemTableEntry(2, 5, False, [2.0]))
    delta.append(MemTableEntry(3, 2, False, [99.0]))
    table.apply_recovered_entries(delta)

    assert_equal(table.slot_count(), 3)
    assert_equal(table.entry_at(0).id, 1)
    assert_true(table.entry_at(0).tombstone)
    assert_equal(table.entry_at(1).id, 2)
    assert_equal(table.entry_at(1).values[0], Float32(2.0))
    assert_equal(table.entry_at(2).id, 3)
    assert_equal(table.entry_at(2).values[0], Float32(3.0))
    assert_equal(table.last_sequence, UInt64(5))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def test_lookup_and_live_count_track_stale_writes_and_slot_reuse() raises:
    var table = MemTable(1)
    assert_equal(table.live_count(), 0)
    assert_equal(table.ordinal_for(-10), -1)
    for index in range(1024):
        var id = ((index * 7919) % 1024) - 512
        table.apply_upsert(id, UInt64(index + 1), [Float32(id)])
        assert_equal(table.ordinal_for(id), index)
    assert_equal(table.live_count(), 1024)
    var saved = table.ordinal_for(-10)
    table.apply_delete(-10, 2000)
    table.apply_delete(-10, 2001)
    table.apply_upsert(-10, 2001, [100.0])
    assert_equal(table.live_count(), 1023)
    table.apply_upsert(-10, 2002, [200.0])
    table.apply_delete(-10, 1999)
    assert_equal(table.live_count(), 1024)
    assert_equal(table.ordinal_for(-10), saved)
    assert_equal(table.get(-10).value().vector[0], Float32(200.0))
    table.apply_delete(9999, 2003)
    assert_equal(table.ordinal_for(9999), 1024)
    assert_equal(table.live_count(), 1024)
    assert_equal(len(table.live_ordinals()), 1024)
    var owned = table.clone()
    owned.apply_delete(-10, 2004)
    owned.apply_upsert(9999, 2005, [9.0])
    assert_equal(table.live_count(), 1024)
    assert_equal(owned.live_count(), 1024)
    assert_true(Bool(table.get(-10)))
    assert_false(Bool(owned.get(-10)))
    assert_false(Bool(table.get(9999)))
    var sorted_entries = table.live_entries()
    var sorted_ordinals = table.live_ordinals(id_order=True)
    for index in range(1024):
        assert_equal(sorted_entries[index].id, index - 512)
        assert_equal(table.id_at(sorted_ordinals[index]), index - 512)


def test_recovery_rebuilds_lookup_before_subsequent_updates() raises:
    var table = MemTable(1)
    var first = List[MemTableEntry]()
    first.append(MemTableEntry(10, 1, False, [1.0]))
    first.append(MemTableEntry(30, 2, False, [3.0]))
    table.apply_recovered_entries(first)
    assert_equal(table.ordinal_for(30), 1)
    var next = List[MemTableEntry]()
    next.append(MemTableEntry(-10, 3, True, List[Float32]()))
    next.append(MemTableEntry(20, 4, False, [2.0]))
    next.append(MemTableEntry(30, 5, True, List[Float32]()))
    table.apply_recovered_entries(next)
    assert_equal(table.ordinal_for(30), 3)
    assert_equal(table.live_count(), 2)
    table.apply_upsert(30, 6, [6.0])
    table.apply_delete(10, 7)
    table.apply_upsert(-10, 8, [-1.0])
    assert_equal(table.live_count(), 3)
    assert_equal(table.get(30).value().vector[0], Float32(6.0))
    assert_false(Bool(table.get(10)))
    assert_equal(table.get(20).value().vector[0], Float32(2.0))
    assert_equal(table.slot_count(), 4)
