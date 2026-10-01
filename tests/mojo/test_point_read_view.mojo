from akasha.document.point_state import PointField, PointState
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from akasha.storage.memtable import MemTable, MemTableEntry
from std.memory import bitcast
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def _point() raises -> PointState:
    var fields: List[PointField] = [
        PointField(0, VectorValue.dense[DType.float32]([1, 2])),
        PointField(1, VectorValue.sparse([SparseElement(3, 4)])),
        PointField(
            2,
            VectorValue.dense[DType.float16](
                [Float16(5), Float16(6), Float16(7)]
            ),
        ),
        PointField(3, VectorValue.binary(9, [UInt8(0), UInt8(1)])),
    ]
    var payload: List[DocumentField] = [
        DocumentField("label", PayloadValue.string("shared"))
    ]
    return PointState.live(1, 8, 3, fields^, payload^)


def test_read_view_preserves_all_field_owners_and_document_version() raises:
    var point = _point()
    var view = MemTableEntry.from_point(point)
    var copied = view.clone()
    var restored = copied.to_point()
    assert_equal(restored.sequence, UInt64(8))
    assert_equal(restored.document_sequence, UInt64(3))
    assert_equal(restored.payload_address(), point.payload_address())
    for field in range(point.field_count()):
        assert_equal(
            restored.field_at(field).address(), point.field_at(field).address()
        )
    assert_equal(view.values()[0], Float32(1))
    assert_equal(view.sparse()[0].term_id, 3)
    assert_equal(
        view.content_bytes(),
        point.field_at(0).value().content_bytes()
        + point.field_at(1).value().content_bytes()
        + point.field_at(2).value().content_bytes()
        + point.field_at(3).value().content_bytes()
        + view.payload_bytes(),
    )
    var table = MemTable(2)
    table.put(view^)
    assert_equal(table.get(1).value().sequence, UInt64(3))


def test_named_only_read_view_has_no_fabricated_default_dense() raises:
    var fields: List[PointField] = [
        PointField(
            2, VectorValue.dense[DType.float16]([Float16(1), Float16(2)])
        )
    ]
    var point = PointState.live(7, 9, 0, fields^, [])
    var view = MemTableEntry.from_point(point)
    assert_false(view.has_dense())
    assert_equal(view.dense_bytes(), 0)
    assert_equal(view.dense_address(), 0)
    assert_equal(view.content_bytes(), 4)
    var table = MemTable(2)
    table.put(view^)
    assert_false(Bool(table.get(7)))
    assert_true(table.is_live_at(table.ordinal_for(7)))


def test_legacy_mutations_preserve_named_owners_until_point_deletion() raises:
    var table = MemTable(2)
    var point = _point()
    table.put(MemTableEntry.from_point(point))
    table.apply_upsert(1, 10, [9, 10])
    table.set_sparse(1, [SparseElement(8, 9)])
    var changed = table.entry_at(table.ordinal_for(1)).to_point()
    assert_equal(changed.field_count(), 4)
    assert_equal(changed.field_at(2).address(), point.field_at(2).address())
    assert_equal(changed.document_sequence, UInt64(10))
    table.apply_delete(1, 11)
    assert_equal(table.entry_at(0).to_point().field_count(), 0)
    table.apply_upsert(1, 12, [3, 4])
    assert_equal(table.entry_at(0).to_point().field_count(), 1)


def test_legacy_descriptor_keeps_low_level_nonfinite_bits() raises:
    var nan = bitcast[DType.float32](UInt32(0x7FC00001))
    var entry = MemTableEntry(1, 1, False, [nan])
    assert_equal(bitcast[DType.uint32](entry.values()[0]), UInt32(0x7FC00001))
    var deleted = MemTableEntry(2, 2, True, [])
    assert_equal(len(deleted.values()), 0)
    assert_equal(len(deleted.fields()), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
