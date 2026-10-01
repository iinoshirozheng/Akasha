from akasha.document.point_state import (
    FieldUpdate,
    PointField,
    PointMutation,
    PointState,
    apply_point_mutation,
)
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.vector_value import VectorValue
from akasha.document.vector_schema import FieldCatalog
from akasha.index.sparse import SparseElement
from akasha.storage.field_catalog import decode_field_catalog_bytes
from akasha.storage.filesystem import read_file_bytes
from std.memory import bitcast
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _catalog() raises -> FieldCatalog:
    return decode_field_catalog_bytes(
        read_file_bytes("tests/fixtures/field-catalog/named-f32-v2.bin")
    )


def _create(id: Int = -42) raises -> PointMutation:
    var updates: List[FieldUpdate] = [
        FieldUpdate.set(0, VectorValue.dense[DType.float32]([1, 2, 3])),
        FieldUpdate.set(1, VectorValue.sparse([SparseElement(2, 3)])),
        FieldUpdate.set(2, VectorValue.dense[DType.float32]([4, 5])),
    ]
    var payload: List[DocumentField] = [
        DocumentField("title", PayloadValue.string("old"))
    ]
    return PointMutation(id, 1, updates^, Optional(payload^))


def _initial(catalog: FieldCatalog) raises -> PointState:
    return apply_point_mutation(Optional[PointState](), _create(), 8, catalog)


def test_partial_update_shares_unmentioned_fields_and_preserves_legacy_sequence() raises:
    var catalog = _catalog()
    var before = _initial(catalog)
    var sparse_only = PointMutation(
        -42, 3, [FieldUpdate.set(1, VectorValue.sparse([]))]
    )
    var after = apply_point_mutation(
        Optional(before.copy()), sparse_only, 9, catalog
    )
    assert_equal(before.sequence, UInt64(8))
    assert_equal(after.sequence, UInt64(9))
    assert_equal(after.document_sequence, UInt64(8))
    assert_equal(before.field_at(0).address(), after.field_at(0).address())
    assert_equal(before.field_at(2).address(), after.field_at(2).address())
    assert_equal(before.payload_address(), after.payload_address())
    assert_true(before.field_at(1).address() != after.field_at(1).address())
    assert_equal(len(before.field_at(1).value().sparse_values()), 1)
    assert_equal(len(after.field_at(1).value().sparse_values()), 0)
    assert_equal(before.legacy_document().value().sequence, UInt64(8))
    assert_equal(after.legacy_document().value().sequence, UInt64(8))


def test_named_only_and_payload_only_points_need_no_default_dense() raises:
    var catalog = _catalog()
    var mutation = PointMutation(
        Int.MIN,
        1,
        [FieldUpdate.set(2, VectorValue.dense[DType.float32]([0, 0]))],
    )
    var point = apply_point_mutation(
        Optional[PointState](), mutation, 8, catalog
    )
    assert_false(point.tombstone)
    assert_equal(point.field_count(), 1)
    assert_equal(point.field_at(0).id, 2)
    assert_equal(point.document_sequence, UInt64(0))
    assert_false(Bool(point.legacy_document()))
    var remove = PointMutation(Int.MIN, 3, [FieldUpdate.remove(2)])
    var payload_only = apply_point_mutation(
        Optional(point.copy()), remove, 9, catalog
    )
    assert_equal(payload_only.field_count(), 0)
    assert_false(payload_only.tombstone)
    assert_false(Bool(payload_only.legacy_document()))


def test_combined_replace_and_explicit_clear_are_one_new_state() raises:
    var catalog = _catalog()
    var before = _initial(catalog)
    var mutation = PointMutation(
        -42,
        3,
        [
            FieldUpdate.set(0, VectorValue.dense[DType.float32]([6, 7, 8])),
            FieldUpdate.remove(1),
            FieldUpdate.set(
                7, VectorValue.dense[DType.float32]([9, 10, 11, 12])
            ),
        ],
        Optional(List[DocumentField]()),
    )
    var after = apply_point_mutation(
        Optional(before.copy()), mutation, 9, catalog
    )
    assert_equal(after.document_sequence, UInt64(9))
    assert_equal(after.field_count(), 3)
    assert_equal(after.field_at(0).id, 0)
    assert_equal(after.field_at(1).id, 2)
    assert_equal(after.field_at(2).id, 7)
    assert_equal(after.ordinal_for(1), -1)
    assert_equal(len(after.payload()), 0)
    assert_equal(len(before.payload()), 1)
    assert_equal(before.field_at(2).address(), after.field_at(1).address())
    var owned = after.legacy_document().value().clone()
    owned.vector[0] = 100
    assert_equal(
        after.field_at(0).value().dense_values[DType.float32]()[0], Float32(6)
    )


def test_delete_and_reinsert_never_inherit_old_owners() raises:
    var catalog = _catalog()
    var before = _initial(catalog)
    var deleted = apply_point_mutation(
        Optional(before.copy()), PointMutation.delete(-42), 9, catalog
    )
    assert_true(deleted.tombstone)
    assert_equal(deleted.field_count(), 0)
    assert_equal(deleted.payload_address(), 0)
    assert_equal(deleted.document_sequence, UInt64(0))
    assert_false(Bool(deleted.legacy_document()))
    with assert_raises():
        _ = deleted.payload()
    with assert_raises():
        _ = apply_point_mutation(
            Optional(deleted.copy()), PointMutation(-42, 3, []), 10, catalog
        )
    var insert = PointMutation(
        -42, 1, [FieldUpdate.set(2, VectorValue.dense[DType.float32]([1, 1]))]
    )
    var after = apply_point_mutation(
        Optional(deleted.copy()), insert, 10, catalog
    )
    assert_equal(after.field_count(), 1)
    assert_equal(after.field_at(0).id, 2)
    assert_equal(len(after.payload()), 0)
    assert_equal(before.field_count(), 3)
    var unknown = apply_point_mutation(
        Optional[PointState](), PointMutation.delete(Int.MAX), 8, catalog
    )
    assert_true(unknown.tombstone)


def test_invalid_later_fields_payload_and_sequences_leave_source_unchanged() raises:
    var catalog = _catalog()
    var before = _initial(catalog)
    var address = before.field_at(0).address()
    for bad_id in [-1, 3, 4_294_967_296]:
        var invalid = PointMutation(
            -42,
            1,
            [
                FieldUpdate.set(0, VectorValue.dense[DType.float32]([9, 9, 9])),
                FieldUpdate.remove(bad_id),
            ],
        )
        with assert_raises():
            _ = apply_point_mutation(
                Optional(before.copy()), invalid, 9, catalog
            )
    var wrong_shape = PointMutation(
        -42, 1, [FieldUpdate.set(2, VectorValue.dense[DType.float32]([1]))]
    )
    with assert_raises():
        _ = apply_point_mutation(
            Optional(before.copy()), wrong_shape, 9, catalog
        )
    var duplicate = PointMutation(
        -42, 1, [FieldUpdate.remove(1), FieldUpdate.remove(1)]
    )
    with assert_raises():
        _ = apply_point_mutation(Optional(before.copy()), duplicate, 9, catalog)
    var descending = PointMutation(
        -42, 1, [FieldUpdate.remove(2), FieldUpdate.remove(1)]
    )
    with assert_raises():
        _ = apply_point_mutation(
            Optional(before.copy()), descending, 9, catalog
        )
    var payload: List[DocumentField] = [
        DocumentField("x", PayloadValue.integer(1)),
        DocumentField("x", PayloadValue.integer(2)),
    ]
    var duplicate_payload = PointMutation(-42, 1, [], Optional(payload^))
    with assert_raises():
        _ = apply_point_mutation(
            Optional(before.copy()), duplicate_payload, 9, catalog
        )
    for sequence in [UInt64(0), UInt64(7), UInt64(8)]:
        with assert_raises():
            _ = apply_point_mutation(
                Optional(before.copy()), _create(), sequence, catalog
            )
    with assert_raises():
        _ = apply_point_mutation(
            Optional(before.copy()), _create(2), 9, catalog
        )
    with assert_raises():
        _ = apply_point_mutation(
            Optional[PointState](), PointMutation(-42, 3, []), 8, catalog
        )
    assert_equal(before.field_at(0).address(), address)
    assert_equal(before.sequence, UInt64(8))
    assert_equal(before.payload()[0].value.as_string(), "old")


def test_migration_watermark_keeps_document_version_and_sequence_boundaries() raises:
    var catalog = _catalog()
    var fields: List[PointField] = [
        PointField(0, VectorValue.dense[DType.float32]([1, 2, 3]))
    ]
    var migrated = PointState.live(42, 7, 2, fields^, [])
    migrated.validate(catalog)
    assert_equal(migrated.legacy_document().value().sequence, UInt64(2))
    var sparse_only = PointMutation(
        42, 3, [FieldUpdate.set(1, VectorValue.sparse([]))]
    )
    var after = apply_point_mutation(
        Optional(migrated.copy()), sparse_only, 8, catalog
    )
    assert_equal(after.document_sequence, UInt64(2))
    var payload: List[DocumentField] = [
        DocumentField("x", PayloadValue.boolean(True))
    ]
    var changed = apply_point_mutation(
        Optional(after.copy()),
        PointMutation(42, 3, [], Optional(payload^)),
        UInt64.MAX,
        catalog,
    )
    assert_equal(changed.sequence, UInt64.MAX)
    assert_equal(changed.document_sequence, UInt64.MAX)
    with assert_raises():
        _ = apply_point_mutation(
            Optional(changed.copy()), sparse_only, UInt64.MAX, catalog
        )


def test_default_field_removal_and_readdition_reset_document_projection() raises:
    var catalog = _catalog()
    var before = _initial(catalog)
    var removed = apply_point_mutation(
        Optional(before.copy()),
        PointMutation(-42, 3, [FieldUpdate.remove(0)]),
        9,
        catalog,
    )
    removed.validate(catalog)
    assert_equal(removed.document_sequence, UInt64(0))
    assert_false(Bool(removed.legacy_document()))
    assert_equal(removed.payload_address(), before.payload_address())
    var restored = apply_point_mutation(
        Optional(removed.copy()),
        PointMutation(
            -42,
            3,
            [FieldUpdate.set(0, VectorValue.dense[DType.float32]([0, 0, 0]))],
        ),
        10,
        catalog,
    )
    restored.validate(catalog)
    assert_equal(restored.document_sequence, UInt64(10))
    assert_equal(
        restored.legacy_document().value().fields[0].value.as_string(), "old"
    )
    var noop = apply_point_mutation(
        Optional(restored.copy()),
        PointMutation(-42, 3, [FieldUpdate.remove(7)]),
        11,
        catalog,
    )
    assert_equal(noop.sequence, UInt64(11))
    assert_equal(noop.document_sequence, UInt64(10))
    assert_equal(noop.field_at(0).address(), restored.field_at(0).address())


def test_invalid_operation_and_complete_state_invariants() raises:
    var catalog = _catalog()
    var before = _initial(catalog)
    for kind in [UInt8(0), UInt8(4), UInt8(255)]:
        with assert_raises():
            _ = apply_point_mutation(
                Optional(before.copy()),
                PointMutation(-42, kind, []),
                9,
                catalog,
            )
    with assert_raises():
        _ = apply_point_mutation(
            Optional(before.copy()),
            PointMutation(-42, 2, [FieldUpdate.remove(0)]),
            9,
            catalog,
        )
    with assert_raises():
        _ = apply_point_mutation(
            Optional(before.copy()),
            PointMutation(-42, 2, [], Optional(List[DocumentField]())),
            9,
            catalog,
        )
    for document_sequence in [UInt64(0), UInt64(9)]:
        var invalid = PointState.live(
            1,
            8,
            document_sequence,
            [PointField(0, VectorValue.dense[DType.float32]([1, 2, 3]))],
            [],
        )
        with assert_raises():
            invalid.validate(catalog)
    var no_dense = PointState.live(1, 8, 1, [], [])
    with assert_raises():
        no_dense.validate(catalog)
    var duplicate = PointState.live(
        1,
        8,
        0,
        [
            PointField(2, VectorValue.dense[DType.float32]([1, 2])),
            PointField(2, VectorValue.dense[DType.float32]([3, 4])),
        ],
        [],
    )
    with assert_raises():
        duplicate.validate(catalog)
    var invalid_version = PointState.deleted(1, 6)
    with assert_raises():
        invalid_version.validate(catalog)
    var legacy = decode_field_catalog_bytes(
        read_file_bytes("tests/fixtures/field-catalog/legacy-v1.bin")
    )
    with assert_raises():
        before.validate(legacy)
    with assert_raises():
        _ = apply_point_mutation(Optional[PointState](), _create(), 8, legacy)
    var malformed_float = PayloadValue(
        3,
        String(),
        0,
        bitcast[DType.float64](UInt64(0x7FF0000000000000)),
        False,
    )
    var payload: List[DocumentField] = [DocumentField("x", malformed_float^)]
    with assert_raises():
        _ = apply_point_mutation(
            Optional(before.copy()),
            PointMutation(-42, 1, [], Optional(payload^)),
            9,
            catalog,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
