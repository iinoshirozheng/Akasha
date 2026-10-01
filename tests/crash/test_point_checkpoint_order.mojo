from akasha import PersistentCollection, CollectionConfig, SparseElement
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    write_file_sync,
    remove_file_if_exists,
    path_exists,
)
from akasha.storage.manifest import load_manifest
from std.ffi import c_int, external_call
from std.os import listdir
from std.testing import assert_equal, assert_false, TestSuite


def _path(suffix: String) -> String:
    return String(
        "/tmp/akasha-point-crash-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
    )


def _fields() raises -> List[VectorFieldSpec]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "half", 0, 2, 0, 0, 1))
    return fields^


def test_migration_and_first_point_checkpoint_recover_each_publication_boundary() raises:
    var source = _path("source")
    var legacy = PersistentCollection.open(source, 2)
    legacy.upsert(1, [1, 0])
    legacy.upsert_sparse(1, [SparseElement(9, 2)])
    legacy.flush()
    legacy.close()
    var names = listdir(source)
    var old_files = List[List[UInt8]]()
    for name in names:
        old_files.append(read_file_bytes(source + "/" + name))
    var old_manifest = load_manifest(source, 2)
    var upgraded = PersistentCollection.open_with_fields(source, _fields())
    var identity = read_file_bytes(source + "/collection.bin")
    var changes: List[PointMutation] = [
        PointMutation(
            1,
            3,
            [
                FieldUpdate.set(0, VectorValue.dense[DType.float32]([3, 0])),
                FieldUpdate.set(
                    2, VectorValue.dense[DType.float16]([Float16(3)])
                ),
            ],
        ),
        PointMutation(
            2,
            1,
            [
                FieldUpdate.set(
                    2, VectorValue.dense[DType.float16]([Float16(4)])
                )
            ],
        ),
    ]
    _ = upgraded.apply_point_batch(changes)
    var accepted_wal = read_file_bytes(source + "/wal.bin")
    upgraded.flush()
    upgraded.close()
    var manifest = read_file_bytes(source + "/manifest.bin")
    var current = load_manifest(source, 2)
    var point_name = current.segments[0].name.copy()
    var point_bytes = read_file_bytes(source + "/" + point_name)

    # 0 old identity; 1 identity temporary; 2 new identity; 3 accepted batch;
    # 4 durable point output; 5 manifest temporary; 6 manifest committed;
    # 7 dense WAL rotated; 8 sparse WAL rotated; 9 retired legacy files removed.
    for boundary in range(10):
        var path = _path("boundary-" + String(boundary))
        ensure_directory(path)
        for index in range(len(names)):
            write_file_sync(path + "/" + names[index], old_files[index])
        if boundary == 1:
            write_file_sync(path + "/collection.bin.tmp", identity)
        if boundary >= 2:
            write_file_sync(path + "/collection.bin", identity)
        if boundary >= 3:
            write_file_sync(path + "/wal.bin", accepted_wal)
        if boundary >= 4:
            write_file_sync(path + "/" + point_name, point_bytes)
        if boundary == 5:
            write_file_sync(path + "/manifest.bin.tmp", manifest)
        if boundary >= 6:
            write_file_sync(path + "/manifest.bin", manifest)
        if boundary >= 7:
            write_file_sync(path + "/wal.bin", [])
        if boundary >= 8:
            write_file_sync(path + "/sparse.wal", [])
        if boundary == 9:
            for index in range(len(old_manifest.segments)):
                ref descriptor = old_manifest.segments[index]
                remove_file_if_exists(path + "/" + descriptor.name)
                if descriptor.sparse_name.byte_length() > 0:
                    remove_file_if_exists(path + "/" + descriptor.sparse_name)
            if old_manifest.hnsw_name:
                remove_file_if_exists(
                    path + "/" + old_manifest.hnsw_name.value()
                )
        var recovered = PersistentCollection.open_with_fields(path, _fields())
        assert_equal(
            recovered.last_sequence(), UInt64(4 if boundary >= 3 else 2)
        )
        assert_equal(
            recovered.get(1).value().vector[0],
            Float32(3 if boundary >= 3 else 1),
        )
        assert_equal(
            recovered.search_sparse_dot([SparseElement(9, 1)], 1)[0].id, 1
        )
        assert_equal(Bool(recovered.get_point(2)), boundary >= 3)
        if boundary >= 3:
            assert_equal(
                recovered.get_point(1)
                .value()
                .field_at(2)
                .value()
                .dense_values[DType.float16]()[0],
                Float16(3),
            )
        if boundary == 4 or boundary == 5:
            assert_false(path_exists(path + "/" + point_name))
        recovered.upsert(3, [5, 0])
        var accepted = recovered.last_sequence()
        recovered.flush()
        recovered.close()
        var again = PersistentCollection.open(path, 2)
        assert_equal(again.last_sequence(), accepted)
        assert_equal(again.get(3).value().vector[0], Float32(5))
        again.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
