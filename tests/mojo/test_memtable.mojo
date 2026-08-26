from akasha.document import DocumentField, PayloadValue
from akasha.storage.memtable import MemTable
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
