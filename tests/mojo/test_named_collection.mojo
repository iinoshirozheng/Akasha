from akasha import PersistentCollection, BatchMutation, CollectionConfig
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from akasha.storage.filesystem import read_file_bytes
from akasha.storage.operations import restore_storage
from akasha.storage.manifest import load_manifest
from akasha.storage.maintenance import DEFAULT_MAINTENANCE_LIBRARY
from std.ffi import c_int, external_call
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def _path(name: String) -> String:
    return String(
        "/tmp/akasha-named-collection-",
        Int(external_call["getpid", c_int]()),
        "-",
        name,
    )


def _fields() raises -> List[VectorFieldSpec]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "image", 0, 2, 0, 0, 3))
    return fields^


def test_public_collection_combined_write_snapshot_checkpoint_and_reopen() raises:
    var path = _path("roundtrip")
    var collection = PersistentCollection.open_with_fields(path, _fields())
    var changes: List[PointMutation] = [
        PointMutation(
            1,
            1,
            [
                FieldUpdate.set(0, VectorValue.dense[DType.float32]([1, 0])),
                FieldUpdate.set(1, VectorValue.sparse([SparseElement(7, 3)])),
                FieldUpdate.set(
                    2,
                    VectorValue.dense[DType.float16](
                        [Float16(2), Float16(0), Float16(0)]
                    ),
                ),
            ],
        ),
        PointMutation(
            2,
            1,
            [
                FieldUpdate.set(
                    2,
                    VectorValue.dense[DType.float16](
                        [Float16(4), Float16(0), Float16(0)]
                    ),
                )
            ],
        ),
    ]
    var accepted = collection.apply_point_batch(changes)
    assert_equal(accepted.last_sequence, UInt64(2))
    var snapshot = collection.snapshot()
    var query = VectorValue.dense[DType.float16](
        [Float16(1), Float16(0), Float16(0)]
    )
    assert_equal(collection.search_field("image", query, 1)[0].id, 2)
    collection.upsert(1, [3, 0])
    assert_equal(collection.get_point(1).value().field_count(), 3)
    assert_equal(
        collection.search_sparse_dot([SparseElement(7, 1)], 1)[0].id, 1
    )
    collection.upsert_sparse(1, [SparseElement(9, 5)])
    assert_equal(collection.get(1).value().sequence, UInt64(3))
    var removal: List[PointMutation] = [
        PointMutation(1, 3, [FieldUpdate.remove(0)])
    ]
    _ = collection.apply_point_batch(removal)
    assert_false(Bool(collection.get(1)))
    assert_equal(len(collection.search_dot([1, 0], 5)), 0)
    collection.flush()
    collection.close()
    assert_equal(snapshot.get(1).value().vector[0], Float32(1))
    assert_equal(snapshot.search_field("image", query, 1)[0].id, 2)
    var reopened = PersistentCollection.open(path, 2)
    assert_equal(reopened.get_point(1).value().field_count(), 2)
    assert_equal(reopened.search_field("image", query, 1)[0].id, 2)
    assert_equal(reopened.last_sequence(), UInt64(5))
    reopened.close()
    snapshot.close()


def test_public_migration_and_invalid_late_field_leave_wal_unchanged() raises:
    var path = _path("migration")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(1, [1, 2])
    legacy.upsert_sparse(1, [SparseElement(1, 1)])
    legacy.flush()
    legacy.close()
    var collection = PersistentCollection.open_with_fields(path, _fields())
    assert_equal(collection.get(1).value().sequence, UInt64(1))
    assert_equal(collection.get_point(1).value().sequence, UInt64(2))
    var before = read_file_bytes(path + "/wal.bin")
    var changes: List[PointMutation] = [
        PointMutation(
            1,
            3,
            [
                FieldUpdate.set(0, VectorValue.dense[DType.float32]([8, 9])),
                FieldUpdate.set(
                    2, VectorValue.dense[DType.float16]([Float16(1)])
                ),
            ],
        )
    ]
    with assert_raises():
        _ = collection.apply_point_batch(changes)
    assert_equal(read_file_bytes(path + "/wal.bin"), before)
    assert_equal(collection.get(1).value().vector[0], Float32(1))
    var batch: List[BatchMutation] = [
        BatchMutation.delete(1),
        BatchMutation.upsert(1, [5, 6]),
    ]
    _ = collection.apply_batch(batch)
    assert_equal(collection.get_point(1).value().field_count(), 1)
    collection.flush()
    collection.compact()
    collection.close()
    var reopened = PersistentCollection.open_with_fields(path, _fields())
    assert_equal(reopened.get(1).value().vector[0], Float32(5))
    assert_equal(reopened.get_point(1).value().field_count(), 1)
    reopened.close()


def test_default_ann_counts_only_present_vectors_and_named_updates_keep_graph() raises:
    var collection = PersistentCollection.open_with_fields(
        _path("ann"), _fields()
    )
    var changes = List[PointMutation]()
    for id in range(160):
        var fields = List[FieldUpdate]()
        if id < 80:
            fields.append(
                FieldUpdate.set(
                    0, VectorValue.dense[DType.float32]([Float32(id), 1])
                )
            )
        fields.append(
            FieldUpdate.set(
                2,
                VectorValue.dense[DType.float16](
                    [Float16(id), Float16(0), Float16(0)]
                ),
            )
        )
        changes.append(PointMutation(id, 1, fields^))
    _ = collection.apply_point_batch(changes)
    assert_equal(collection._memtable.dense_live_count(), 80)
    assert_equal(collection.search_dot_approx([1, 0], 100, 160)[0].id, 79)
    assert_equal(len(collection.search_dot_approx([1, 0], 100, 160)), 80)
    assert_true(collection.hnsw_available())
    var slots = collection.hnsw_slot_count()
    var named: List[PointMutation] = [
        PointMutation(
            1,
            3,
            [
                FieldUpdate.set(
                    2,
                    VectorValue.dense[DType.float16](
                        [Float16(9), Float16(0), Float16(0)]
                    ),
                )
            ],
        )
    ]
    _ = collection.apply_point_batch(named)
    assert_equal(collection.hnsw_slot_count(), slots)
    assert_equal(collection.get(1).value().sequence, UInt64(2))
    var removal: List[PointMutation] = [
        PointMutation(1, 3, [FieldUpdate.remove(0)]),
        PointMutation.delete(2),
    ]
    _ = collection.apply_point_batch(removal)
    assert_equal(collection._memtable.dense_live_count(), 78)
    collection.rebuild_hnsw()
    assert_true(collection.hnsw_available())
    assert_equal(collection.hnsw_slot_count(), 78)
    collection.close()


def test_named_collection_background_compaction_snapshot_backup_and_restore() raises:
    for background in [False, True]:
        var suffix = String(Int(background))
        var path = _path("maintenance-" + suffix)
        var collection = PersistentCollection.open_with_fields(
            path,
            _fields(),
            maintenance_library_path=DEFAULT_MAINTENANCE_LIBRARY if background else "/missing/akasha-worker.so",
        )
        collection.upsert(1, [1, 0])
        collection.flush()
        var snapshot = collection.snapshot()
        for id in range(2, 9):
            var update: List[PointMutation] = [
                PointMutation(
                    id,
                    1,
                    [
                        FieldUpdate.set(
                            2,
                            VectorValue.dense[DType.float16](
                                [Float16(id), Float16(0), Float16(0)]
                            ),
                        )
                    ],
                )
            ]
            _ = collection.apply_point_batch(update)
            collection.flush()
            _ = collection.wait_for_maintenance()
        collection.compact()
        assert_equal(len(load_manifest(path, 2).segments), 1)
        assert_equal(snapshot.get(1).value().vector[0], Float32(1))
        assert_false(Bool(snapshot.get_point(8)))
        var backup = _path("backup-" + suffix)
        assert_equal(collection.backup_to(backup).live_points, 8)
        collection.close()
        snapshot.close()
        var restored_path = _path("restored-" + suffix)
        assert_equal(restore_storage(backup, restored_path, 2).live_points, 8)
        var restored = PersistentCollection.open(restored_path, 2)
        assert_equal(
            restored.get_point(8)
            .value()
            .field_at(0)
            .value()
            .dense_values[DType.float16]()[0],
            Float16(8),
        )
        restored.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
