from akasha.document.point_state import FieldUpdate, PointMutation, PointState
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.vector_schema import FieldCatalog
from akasha.document.vector_value import VectorValue
from akasha.storage.field_catalog import decode_field_catalog_bytes
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    write_file_sync,
)
from akasha.storage.point_segment import (
    decode_point_segment,
    encode_point_segment,
)
from akasha.storage.point_table import PointTable
from akasha.storage.point_wal import (
    FieldWalReader,
    PointWalBatch,
    decode_point_batch,
)
from std.ffi import c_int, external_call
from std.memory import ArcPointer
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def _catalog() raises -> ArcPointer[FieldCatalog]:
    return ArcPointer(
        decode_field_catalog_bytes(
            read_file_bytes("tests/fixtures/field-catalog/named-f32-v2.bin")
        )
    )


def _path(name: String) raises -> String:
    var directory = String(
        "/tmp/akasha-point-table-", Int(external_call["getpid", c_int]())
    )
    ensure_directory(directory)
    return directory + "/" + name


def _create(id: Int) raises -> PointMutation:
    var payload: List[DocumentField] = [
        DocumentField("text", PayloadValue.string("before"))
    ]
    return PointMutation(
        id,
        1,
        [
            FieldUpdate.set(0, VectorValue.dense[DType.float32]([1, 2, 3])),
            FieldUpdate.set(1, VectorValue.sparse([])),
            FieldUpdate.set(2, VectorValue.dense[DType.float32]([4, 5])),
        ],
        Optional(payload^),
    )


def test_durable_batch_repeated_ids_and_replay_share_exact_atomic_boundary() raises:
    var catalog = _catalog()
    var table = PointTable(catalog.copy(), 7)
    var path = _path("batch.wal")
    var mutations: List[PointMutation] = [
        _create(-42),
        PointMutation(-42, 3, [FieldUpdate.remove(2)]),
        PointMutation.delete(Int.MIN),
        PointMutation(Int.MAX, 1, []),
    ]
    var result = table.append_batch(path, mutations)
    assert_equal(result.first_sequence, UInt64(8))
    assert_equal(result.last_sequence, UInt64(11))
    assert_equal(table.last_sequence(), UInt64(11))
    assert_equal(table.live_count(), 2)
    assert_equal(table.slot_count(), 3)
    assert_equal(table.get(-42).value().sequence, UInt64(9))
    assert_equal(table.get(-42).value().document_sequence, UInt64(8))
    assert_equal(table.get(-42).value().ordinal_for(2), -1)
    assert_false(Bool(table.get(Int.MIN)))
    assert_equal(table.get(Int.MAX).value().field_count(), 0)
    var reader = FieldWalReader(path, catalog.copy())
    var envelope = reader.read_next()
    assert_true(Bool(envelope))
    var recovered = PointTable(catalog.copy(), 7)
    recovered.replay(envelope.value().point_batch())
    assert_equal(recovered.last_sequence(), UInt64(11))
    assert_equal(recovered.get(-42).value().document_sequence, UInt64(8))
    assert_equal(recovered.live_count(), 2)
    assert_false(Bool(reader.read_next()))


def test_invalid_later_mutation_never_appends_or_publishes_earlier_changes() raises:
    var catalog = _catalog()
    var table = PointTable(catalog.copy(), 7)
    var path = _path("invalid.wal")
    var initial: List[PointMutation] = [_create(1)]
    _ = table.append_batch(path, initial)
    var before = read_file_bytes(path)
    var old = table.get(1)
    for kind in range(3):
        var invalid = PointMutation(999, 3, [])
        if kind == 1:
            invalid = PointMutation(1, 3, [FieldUpdate.remove(99)])
        elif kind == 2:
            invalid = PointMutation(
                1,
                3,
                [FieldUpdate.set(2, VectorValue.dense[DType.float32]([1]))],
            )
        var mutations: List[PointMutation] = [PointMutation.delete(1), invalid^]
        with assert_raises():
            _ = table.append_batch(path, mutations)
        assert_equal(read_file_bytes(path), before)
        assert_equal(table.last_sequence(), UInt64(8))
        assert_equal(table.live_count(), 1)
        assert_equal(
            table.get(1).value().payload_address(),
            old.value().payload_address(),
        )
    var valid: List[PointMutation] = [PointMutation.delete(1)]
    _ = table.append_batch(path, valid)
    assert_equal(table.last_sequence(), UInt64(9))


def test_append_failure_keeps_state_and_requires_reopen_before_another_write() raises:
    var catalog = _catalog()
    var table = PointTable(catalog.copy(), 7)
    var path = _path("failure.wal")
    var initial: List[PointMutation] = [_create(1)]
    _ = table.append_batch(path, initial)
    var before = table.get(1)
    var blocker = _path("file-as-parent")
    write_file_sync(blocker, [1])
    var erase: List[PointMutation] = [PointMutation.delete(1)]
    with assert_raises():
        _ = table.append_batch(blocker + "/wal.bin", erase)
    assert_equal(table.last_sequence(), UInt64(8))
    assert_equal(table.live_count(), 1)
    assert_equal(
        table.get(1).value().field_at(0).address(),
        before.value().field_at(0).address(),
    )
    var original = read_file_bytes(path)
    with assert_raises():
        _ = table.append_batch(path, erase)
    assert_equal(read_file_bytes(path), original)


def test_old_point_handles_keep_owners_through_partial_update_delete_and_reinsert() raises:
    var catalog = _catalog()
    var table = PointTable(catalog.copy(), 7)
    var path = _path("owners.wal")
    var initial: List[PointMutation] = [_create(1)]
    _ = table.append_batch(path, initial)
    var before = table.get(1)
    var patch: List[PointMutation] = [
        PointMutation(1, 3, [FieldUpdate.remove(1)])
    ]
    _ = table.append_batch(path, patch)
    var after = table.get(1)
    assert_equal(
        before.value().field_at(0).address(),
        after.value().field_at(0).address(),
    )
    assert_equal(
        before.value().payload_address(), after.value().payload_address()
    )
    var replace: List[PointMutation] = [
        PointMutation.delete(1),
        PointMutation(
            1, 1, [FieldUpdate.set(2, VectorValue.dense[DType.float32]([9, 8]))]
        ),
    ]
    _ = table.append_batch(path, replace)
    assert_equal(table.slot_count(), 1)
    assert_equal(table.live_count(), 1)
    assert_equal(table.get(1).value().field_count(), 1)
    assert_equal(table.get(1).value().document_sequence, UInt64(0))
    assert_equal(before.value().field_count(), 3)
    assert_equal(before.value().payload()[0].value.as_string(), "before")


def test_checkpoint_watermark_skips_covered_batches_but_rejects_partial_and_repeated_replay() raises:
    var catalog = _catalog()
    var bytes = read_file_bytes("tests/fixtures/field-envelopes/base-v4.bin")
    var segment = decode_point_segment(bytes, catalog[])
    var checkpoint_sequence = segment.last_sequence
    var table = PointTable(
        catalog.copy(), checkpoint_sequence, segment.points.copy()
    )
    assert_equal(table.last_sequence(), UInt64(10))
    var covered = PointWalBatch(8, [_create(99)])
    table.replay(covered)
    assert_false(Bool(table.get(99)))
    var crossing = PointWalBatch(
        10, [PointMutation.delete(-42), PointMutation.delete(Int.MAX)]
    )
    with assert_raises():
        table.replay(crossing)
    assert_true(Bool(table.get(-42)))
    var next = PointWalBatch(11, [PointMutation.delete(-42)])
    table.replay(next)
    assert_false(Bool(table.get(-42)))
    with assert_raises():
        table.replay(next)
    assert_equal(table.last_sequence(), UInt64(11))
    var encoded = encode_point_segment(
        1, 0, table.last_sequence(), table.live_points(), catalog[]
    )
    var restored = decode_point_segment(encoded, catalog[])
    assert_equal(restored.points[0].id, 0)
    assert_equal(restored.points[1].id, Int.MAX)


def test_replay_preconditions_are_atomic_and_sequence_exhaustion_cannot_append() raises:
    var catalog = _catalog()
    var table = PointTable(catalog.copy(), 7)
    var invalid = PointWalBatch(8, [_create(1), PointMutation(99, 3, [])])
    with assert_raises():
        table.replay(invalid)
    assert_equal(table.last_sequence(), UInt64(7))
    assert_equal(table.slot_count(), 0)
    var maxed = PointTable(catalog.copy(), UInt64.MAX)
    var path = _path("exhausted.wal")
    var next: List[PointMutation] = [_create(1)]
    with assert_raises():
        _ = maxed.append_batch(path, next)
    assert_false(path_exists(path))
    var empty = List[PointMutation]()
    with assert_raises():
        _ = table.append_batch(path, empty)
    assert_false(path_exists(path))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def test_delta_capture_includes_sparse_only_changes_and_tombstones_in_id_order() raises:
    var catalog = _catalog()
    var table = PointTable(catalog.copy(), 7)
    var path = _path("delta.wal")
    var initial: List[PointMutation] = [_create(9), _create(-3)]
    _ = table.append_batch(path, initial)
    var checkpoint = table.last_sequence()
    var edits: List[PointMutation] = [
        PointMutation(9, 3, [FieldUpdate.remove(1)]),
        PointMutation.delete(-3),
    ]
    _ = table.append_batch(path, edits)
    var delta = table.points_after(checkpoint)
    assert_equal(len(delta), 2)
    assert_equal(delta[0].id, -3)
    assert_true(delta[0].tombstone)
    assert_equal(delta[1].id, 9)
    assert_equal(delta[1].sequence, checkpoint + 1)
    assert_equal(delta[1].document_sequence, UInt64(8))
    assert_equal(
        delta[1].field_at(0).value().dense_values[DType.float32]()[0],
        Float32(1),
    )
    assert_equal(len(table.points_after(table.last_sequence())), 0)
