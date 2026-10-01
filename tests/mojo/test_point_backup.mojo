from akasha.common.config import CollectionConfig
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.storage.field_catalog import load_field_catalog
from akasha.storage.filesystem import (
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from akasha.storage.operations import (
    CheckpointCopy,
    copy_checkpoint,
    inspect_storage,
    restore_storage,
)
from akasha.storage.point_store import PointStore
from std.ffi import c_int, external_call
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, TestSuite


def _path(suffix: String) -> String:
    return String(
        "/tmp/akasha-point-backup-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
    )


def _fields() raises -> List[VectorFieldSpec]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "half", 0, 2, 0, 0, 3))
    fields.append(VectorFieldSpec(3, "bits", 3, 5, 3, 0, 9))
    return fields^


def _seed(path: String) raises -> PointStore:
    var store = PointStore.open(path, _fields())
    var mutations: List[PointMutation] = [
        PointMutation(
            1,
            1,
            [
                FieldUpdate.set(
                    2,
                    VectorValue.dense[DType.float16](
                        [Float16(1), Float16(2), Float16(3)]
                    ),
                ),
                FieldUpdate.set(3, VectorValue.binary(9, [UInt8(1), UInt8(1)])),
            ],
        )
    ]
    _ = store.apply_batch(mutations)
    store.flush()
    return store^


def _capture(path: String) raises -> CheckpointCopy:
    var catalog = ArcPointer(load_field_catalog(path))
    return CheckpointCopy(
        load_manifest(path, 2),
        Optional(CollectionConfig.defaults(2)),
        1,
        catalog=Optional(catalog),
    )


def test_streamed_point_backup_restores_exact_identity_and_native_fields() raises:
    var path = _path("source")
    var backup = _path("backup")
    var target = _path("restore")
    var store = _seed(path)
    var captured = _capture(path)
    var later: List[PointMutation] = [PointMutation.delete(1)]
    _ = store.apply_batch(later)
    copy_checkpoint(path, backup, captured, 1)
    assert_equal(inspect_storage(backup, 2).live_points, 1)
    assert_equal(
        read_file_bytes(backup + "/collection.bin"),
        read_file_bytes(path + "/collection.bin"),
    )
    assert_equal(restore_storage(backup, target, 2).last_sequence, UInt64(1))
    var restored = PointStore.open(target, _fields())
    var point = restored.get(1)
    assert_equal(
        point.value().field_at(0).value().dense_values[DType.float16]()[2],
        Float16(3),
    )
    assert_equal(point.value().field_at(1).value().binary_values()[1], UInt8(1))
    assert_false(path_exists(backup + "/wal.bin"))
    restored.close()
    store.close()


def test_point_copy_rejects_corruption_without_committing_target() raises:
    var path = _path("corrupt-source")
    var target = _path("corrupt-target")
    var store = _seed(path)
    var captured = _capture(path)
    var source = path + "/" + captured.manifest.segments[0].name
    var bytes = read_file_bytes(source)
    bytes[len(bytes) - 1] ^= 1
    write_file_sync(source, bytes)
    with assert_raises():
        copy_checkpoint(path, target, captured, 7)
    assert_false(path_exists(target + "/manifest.bin"))
    with assert_raises():
        _ = inspect_storage(path, 2)
    assert_equal(read_file_bytes(source), bytes)
    store.close()


def test_point_copy_rejects_foreign_named_schema_before_manifest_commit() raises:
    var path = _path("mismatch-source")
    var target = _path("mismatch-target")
    var store = _seed(path)
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    var foreign = PointStore.open(target, fields^)
    foreign.close()
    remove_file_if_exists(target + "/wal.bin")
    var captured = _capture(path)
    var identity = read_file_bytes(target + "/collection.bin")
    with assert_raises():
        copy_checkpoint(path, target, captured)
    assert_false(path_exists(target + "/manifest.bin"))
    assert_equal(read_file_bytes(target + "/collection.bin"), identity)
    store.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
