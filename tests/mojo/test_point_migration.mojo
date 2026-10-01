from akasha import CollectionConfig, PersistentCollection, SparseElement
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import (
    FieldCatalog,
    VectorFieldSpec,
    legacy_vector_fields,
)
from akasha.document.vector_value import VectorValue
from akasha.storage.field_catalog import publish_field_catalog
from akasha.storage.filesystem import (
    append_file_sync,
    read_file_bytes,
    write_file_sync,
)
from akasha.storage.point_migration import (
    preflight_migrating_points,
    point_table_from_legacy,
)
from akasha.storage.memtable import MemTable, MemTableEntry
from akasha.storage.point_wal import encode_point_batch
from std.ffi import c_int, external_call
from std.memory import ArcPointer, bitcast
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def _path(suffix: String) -> String:
    return String(
        "/tmp/akasha-point-migration-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
    )


def _catalog(cutover: UInt64) raises -> ArcPointer[FieldCatalog]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "image", 0, 0, 1, 0, 3))
    return ArcPointer(FieldCatalog(1, cutover, fields^))


def _seed(path: String, checkpoint: Bool) raises -> UInt64:
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1, 2])
    collection.upsert_sparse(1, [SparseElement(9, 3)])
    collection.upsert(2, [4, 5])
    if checkpoint:
        collection.flush()
    collection.delete(2)
    collection.upsert(2, [6, 7])
    collection.upsert_sparse(2, [SparseElement(8, 2)])
    var last = collection.last_sequence()
    collection.close()
    return last


def test_legacy_cutover_preserves_document_versions_and_publishes_reopenable_identity() raises:
    for checkpoint in [False, True]:
        var path = _path("cutover-" + String(Int(checkpoint)))
        var cutover = _seed(path, checkpoint)
        var catalog = _catalog(cutover)
        var original_identity = read_file_bytes(path + "/collection.bin")
        var wal = read_file_bytes(path + "/wal.bin")
        var result = preflight_migrating_points(path, catalog.copy())
        assert_equal(result.points.value().last_sequence(), cutover)
        assert_equal(result.points.value().get(1).value().sequence, cutover)
        assert_equal(
            result.points.value().get(1).value().document_sequence, UInt64(1)
        )
        assert_equal(
            result.points.value().get(2).value().document_sequence, UInt64(5)
        )
        assert_equal(
            result.points.value()
            .get(2)
            .value()
            .field_at(1)
            .value()
            .sparse_values()[0]
            .term_id,
            8,
        )
        assert_equal(
            read_file_bytes(path + "/collection.bin"), original_identity
        )
        publish_field_catalog(path, catalog[], original_identity)
        var reopened = preflight_migrating_points(path, catalog.copy())
        assert_equal(
            reopened.points.value().get(1).value().document_sequence, UInt64(1)
        )
        assert_equal(read_file_bytes(path + "/wal.bin"), wal)


def test_mixed_replay_finishes_sparse_at_cutover_then_applies_atomic_fields() raises:
    var path = _path("mixed")
    var cutover = _seed(path, True)
    var catalog = _catalog(cutover)
    var mutations: List[PointMutation] = [
        PointMutation(
            1,
            3,
            [
                FieldUpdate.remove(1),
                FieldUpdate.set(2, VectorValue.dense[DType.float32]([9, 8, 7])),
            ],
        ),
        PointMutation.delete(2),
        PointMutation(
            2,
            1,
            [FieldUpdate.set(2, VectorValue.dense[DType.float32]([6, 5, 4]))],
        ),
    ]
    var bytes = encode_point_batch(cutover + 1, mutations, catalog[])
    append_file_sync(path + "/wal.bin", bytes)
    var original = read_file_bytes(path + "/wal.bin")
    var result = preflight_migrating_points(path, catalog.copy())
    assert_equal(result.points.value().last_sequence(), cutover + 3)
    var one = result.points.value().get(1)
    assert_equal(one.value().document_sequence, UInt64(1))
    assert_equal(one.value().ordinal_for(1), -1)
    assert_equal(one.value().field_at(1).id, 2)
    var two = result.points.value().get(2)
    assert_equal(two.value().document_sequence, UInt64(0))
    assert_equal(two.value().field_count(), 1)
    assert_equal(two.value().field_at(0).id, 2)
    assert_equal(read_file_bytes(path + "/wal.bin"), original)


def test_every_torn_new_batch_preserves_only_legacy_state_and_source_bytes() raises:
    var path = _path("torn")
    var cutover = _seed(path, False)
    var catalog = _catalog(cutover)
    var legacy = read_file_bytes(path + "/wal.bin")
    var mutations: List[PointMutation] = [
        PointMutation.delete(1),
        PointMutation.delete(2),
    ]
    var bytes = encode_point_batch(cutover + 1, mutations, catalog[])
    for count in range(len(bytes)):
        var torn = legacy.copy()
        torn.extend(Span(bytes)[:count])
        write_file_sync(path + "/wal.bin", torn)
        var result = preflight_migrating_points(path, catalog.copy())
        assert_equal(result.points.value().last_sequence(), cutover)
        assert_equal(result.points.value().live_count(), 2)
        assert_equal(result.wal_valid_length, len(legacy))
        assert_equal(result.wal_source_length, len(torn))
        assert_equal(read_file_bytes(path + "/wal.bin"), torn)


def test_wrong_cutover_and_late_new_patch_fail_before_any_repair() raises:
    var path = _path("invalid")
    var cutover = _seed(path, True)
    var wal = read_file_bytes(path + "/wal.bin")
    for wrong in [cutover - 1, cutover + 1]:
        with assert_raises():
            _ = preflight_migrating_points(path, _catalog(wrong))
    var catalog = _catalog(cutover)
    var mutations: List[PointMutation] = [
        PointMutation.delete(1),
        PointMutation(999, 3, []),
    ]
    var invalid = encode_point_batch(cutover + 1, mutations, catalog[])
    append_file_sync(path + "/wal.bin", invalid)
    var source = read_file_bytes(path + "/wal.bin")
    with assert_raises():
        _ = preflight_migrating_points(path, catalog.copy())
    assert_equal(read_file_bytes(path + "/wal.bin"), source)


def test_published_upgrade_combined_write_and_reopen_use_one_wal_commit() raises:
    var path = _path("write-reopen")
    var cutover = _seed(path, True)
    var catalog = _catalog(cutover)
    var recovered = preflight_migrating_points(path, catalog.copy())
    var identity = read_file_bytes(path + "/collection.bin")
    publish_field_catalog(path, catalog[], identity)
    var old_sparse = read_file_bytes(path + "/sparse.wal")
    var mutations: List[PointMutation] = [
        PointMutation(
            1,
            3,
            [
                FieldUpdate.set(0, VectorValue.dense[DType.float32]([10, 11])),
                FieldUpdate.set(1, VectorValue.sparse([SparseElement(13, 14)])),
                FieldUpdate.set(
                    2, VectorValue.dense[DType.float32]([15, 16, 17])
                ),
            ],
        )
    ]
    var result = recovered.points.value().append_batch(
        path + "/wal.bin", mutations
    )
    assert_equal(result.first_sequence, cutover + 1)
    assert_equal(result.last_sequence, cutover + 1)
    var reopened = preflight_migrating_points(path, catalog.copy())
    var point = reopened.points.value().get(1)
    assert_equal(point.value().sequence, cutover + 1)
    assert_equal(point.value().document_sequence, cutover + 1)
    assert_equal(
        point.value().field_at(0).value().dense_values[DType.float32]()[0],
        Float32(10),
    )
    assert_equal(
        point.value().field_at(1).value().sparse_values()[0].term_id, 13
    )
    assert_equal(
        point.value().field_at(2).value().dense_values[DType.float32]()[2],
        Float32(17),
    )
    assert_equal(read_file_bytes(path + "/sparse.wal"), old_sparse)


def test_cutover_shares_accepted_legacy_owners_and_rejects_nonfinite_authority() raises:
    var table = MemTable(2)
    table.apply_upsert(1, 1, [1, 2])
    table.set_sparse(1, [SparseElement(2, 3)])
    var point = table.entry_ref_at(0).to_point()
    var migrated = point_table_from_legacy(table, _catalog(3))
    var after = migrated.get(1)
    assert_equal(after.value().sequence, UInt64(3))
    assert_equal(after.value().document_sequence, UInt64(1))
    assert_equal(after.value().payload_address(), point.payload_address())
    assert_equal(
        after.value().field_at(0).address(), point.field_at(0).address()
    )
    assert_equal(
        after.value().field_at(1).address(), point.field_at(1).address()
    )
    table.put(
        MemTableEntry(
            2,
            2,
            False,
            [bitcast[DType.float32](UInt32(0x7FC00001)), Float32(0)],
        )
    )
    with assert_raises():
        _ = point_table_from_legacy(table, _catalog(3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
