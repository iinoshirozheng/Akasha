from akasha import CollectionConfig, PersistentCollection, SparseElement
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.storage.filesystem import (
    path_exists,
    read_file_bytes,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from akasha.storage.point_store import PointStore
from std.ffi import c_int, external_call
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def _path(suffix: String) -> String:
    return String(
        "/tmp/akasha-point-store-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
    )


def _fields() raises -> List[VectorFieldSpec]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "image", 0, 0, 1, 0, 3))
    fields.append(VectorFieldSpec(3, "half", 0, 2, 0, 0, 2))
    fields.append(VectorFieldSpec(4, "bits", 3, 5, 3, 0, 9))
    fields.append(VectorFieldSpec(5, "patches", 2, 0, 0, 0, 2))
    return fields^


def _create(id: Int = 1) raises -> PointMutation:
    return PointMutation(
        id,
        1,
        [
            FieldUpdate.set(0, VectorValue.dense[DType.float32]([1, 2])),
            FieldUpdate.set(1, VectorValue.sparse([SparseElement(9, 3)])),
            FieldUpdate.set(2, VectorValue.dense[DType.float32]([4, 5, 6])),
            FieldUpdate.set(
                3, VectorValue.dense[DType.float16]([Float16(0.5), Float16(-2)])
            ),
            FieldUpdate.set(4, VectorValue.binary(9, [UInt8(0xA5), UInt8(1)])),
            FieldUpdate.set(
                5, VectorValue.multivector[DType.float32](2, [7, 8, 9, 10])
            ),
        ],
    )


def test_new_store_atomic_typed_batch_wal_reopen_and_close_ownership() raises:
    var path = _path("wal")
    var store = PointStore.open(path, _fields())
    var batch: List[PointMutation] = [_create()]
    _ = store.apply_batch(batch)
    var point = store.get(1)
    assert_equal(point.value().field_count(), 6)
    with assert_raises():
        _ = PointStore.open(path, _fields())
    store.close()
    store.close()
    assert_equal(
        point.value().field_at(3).value().dense_values[DType.float16]()[1],
        Float16(-2),
    )
    with assert_raises():
        _ = store.get(1)
    var reopened = PointStore.open(path, _fields())
    assert_equal(reopened.last_sequence(), UInt64(1))
    assert_equal(
        reopened.get(1).value().field_at(4).value().binary_values()[1], UInt8(1)
    )
    assert_equal(reopened.get(1).value().field_at(5).value().row_count(), 2)
    reopened.close()


def test_base_delta_checkpoint_and_compaction_reopen_complete_point_states() raises:
    var path = _path("checkpoint")
    var store = PointStore.open(path, _fields())
    var initial: List[PointMutation] = [_create(9), _create(-3)]
    _ = store.apply_batch(initial)
    store.flush()
    var base_manifest = load_manifest(path, 2)
    assert_equal(len(base_manifest.segments), 1)
    var base_path = path + "/" + base_manifest.segments[0].name
    var base_bytes = read_file_bytes(base_path)
    var changes: List[PointMutation] = [
        PointMutation.delete(-3),
        PointMutation(9, 3, [FieldUpdate.remove(1)]),
    ]
    _ = store.apply_batch(changes)
    store.flush()
    assert_equal(read_file_bytes(base_path), base_bytes)
    assert_equal(len(load_manifest(path, 2).segments), 2)
    assert_equal(len(read_file_bytes(path + "/wal.bin")), 0)
    store.close()
    var reopened = PointStore.open(path, _fields())
    assert_false(Bool(reopened.get(-3)))
    assert_equal(reopened.get(9).value().field_count(), 5)
    assert_equal(reopened.get(9).value().document_sequence, UInt64(1))
    reopened.compact()
    assert_equal(len(load_manifest(path, 2).segments), 1)
    assert_false(path_exists(base_path))
    reopened.close()
    var compacted = PointStore.open(path, _fields())
    assert_equal(compacted.last_sequence(), UInt64(4))
    assert_equal(compacted.get(9).value().field_count(), 5)
    compacted.close()


def test_legacy_upgrade_first_checkpoint_replaces_legacy_segments_and_keeps_versions() raises:
    var path = _path("upgrade")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(1, [1, 2])
    legacy.upsert_sparse(1, [SparseElement(2, 3)])
    legacy.flush()
    legacy.close()
    var old_manifest = load_manifest(path, 2)
    var old_base = path + "/" + old_manifest.segments[0].name
    var store = PointStore.open(path, _fields())
    assert_equal(store.last_sequence(), UInt64(2))
    assert_equal(store.get(1).value().document_sequence, UInt64(1))
    var edits: List[PointMutation] = [
        PointMutation(
            1,
            3,
            [FieldUpdate.set(2, VectorValue.dense[DType.float32]([9, 8, 7]))],
        )
    ]
    _ = store.apply_batch(edits)
    store.flush()
    assert_equal(len(load_manifest(path, 2).segments), 1)
    assert_false(path_exists(old_base))
    store.close()
    var reopened = PointStore.open(path, _fields())
    assert_equal(reopened.get(1).value().document_sequence, UInt64(1))
    assert_equal(reopened.get(1).value().field_count(), 3)
    reopened.close()


def test_schema_mismatch_and_corrupt_recovery_never_repair_sources() raises:
    var path = _path("failure")
    var store = PointStore.open(path, _fields())
    var initial: List[PointMutation] = [_create()]
    _ = store.apply_batch(initial)
    store.flush()
    store.close()
    var changed = _fields()
    changed[2].name = "different"
    var identity = read_file_bytes(path + "/collection.bin")
    with assert_raises():
        _ = PointStore.open(path, changed^)
    assert_equal(read_file_bytes(path + "/collection.bin"), identity)
    var manifest = load_manifest(path, 2)
    var segment_path = path + "/" + manifest.segments[0].name
    var bytes = read_file_bytes(segment_path)
    bytes[len(bytes) - 1] ^= 1
    write_file_sync(segment_path, bytes)
    var tail: List[UInt8] = [1, 2, 3]
    write_file_sync(path + "/wal.bin", tail)
    with assert_raises():
        _ = PointStore.open(path, _fields())
    assert_equal(read_file_bytes(path + "/wal.bin"), tail)
    assert_equal(read_file_bytes(path + "/collection.bin"), identity)


def test_noop_flush_preserves_manifest_and_empty_collection_can_reopen() raises:
    var path = _path("empty")
    var store = PointStore.open(path, _fields())
    store.flush()
    var manifest = read_file_bytes(path + "/manifest.bin")
    store.flush()
    assert_equal(read_file_bytes(path + "/manifest.bin"), manifest)
    store.close()
    var reopened = PointStore.open(path, _fields())
    assert_equal(reopened.last_sequence(), UInt64(0))
    assert_false(Bool(reopened.get(1)))
    reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
