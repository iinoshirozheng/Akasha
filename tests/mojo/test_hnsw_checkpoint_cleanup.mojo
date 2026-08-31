from akasha import CollectionConfig, PersistentCollection, SparseElement
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from akasha.storage.sparse_store import (
    append_sparse_wal,
    SparseWalRecord,
)
from akasha.storage.wal import append_wal, WalRecord
from std.ffi import c_int, external_call
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(path: String) raises:
    ensure_directory(path)
    for name in [
        "wal.bin",
        "wal.bin.tmp",
        "sparse.wal",
        "sparse.wal.tmp",
        "manifest.bin",
        "manifest.bin.tmp",
        "collection.bin",
        "collection.bin.tmp",
        "collection.lock",
        "hnsw-user.bin",
        "hnsw-999.bin",
        "hnsw-80.bin.user",
    ]:
        remove_file_if_exists(path + "/" + name)
    for sequence in range(100):
        for prefix in [
            "segment-base-",
            "segment-delta-",
            "sparse-base-",
            "sparse-delta-",
            "hnsw-",
        ]:
            remove_file_if_exists(
                path + "/" + prefix + String(sequence) + ".bin"
            )


def _remove_empty_directory(path: String) raises:
    var owned_path = String(copy=path)
    var result = external_call["rmdir", c_int](
        owned_path.as_c_string_slice()
    )
    if result != 0:
        raise Error("test fault directory cleanup failed")


def test_flush_removes_only_prior_manifest_named_hnsw_sidecar() raises:
    var path = String("/tmp/akasha-task22-checkpoint-cleanup")
    _reset(path)
    var config = CollectionConfig.defaults(1)
    var collection = PersistentCollection.open_with_config(path, config.copy())
    for id in range(1, 81):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    var prior = load_manifest(path, 1)
    var prior_name = prior.hnsw_name.value()
    assert_true(path_exists(path + "/" + prior_name))

    write_file_sync(path + "/hnsw-user.bin", [UInt8(1)])
    write_file_sync(path + "/hnsw-999.bin", [UInt8(2)])
    write_file_sync(path + "/hnsw-80.bin.user", [UInt8(3)])
    collection.upsert(81, [81.0])
    collection.flush()

    var current = load_manifest(path, 1)
    assert_true(Bool(current.hnsw_name))
    assert_true(path_exists(path + "/" + current.hnsw_name.value()))
    assert_false(path_exists(path + "/" + prior_name))
    assert_true(path_exists(path + "/hnsw-user.bin"))
    assert_true(path_exists(path + "/hnsw-999.bin"))
    assert_true(path_exists(path + "/hnsw-80.bin.user"))
    assert_equal(current.generation, prior.generation + UInt64(1))
    collection.close()


def test_compaction_preserves_v3_sidecar_and_advances_generation() raises:
    var path = String("/tmp/akasha-task22-compaction-sidecar")
    _reset(path)
    var config = CollectionConfig.defaults(1)
    var collection = PersistentCollection.open_with_config(
        path,
        config.copy(),
        maintenance_library_path="/tmp/akasha-no-maintenance-worker.so",
    )
    for id in range(1, 81):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    collection.upsert(81, [81.0])
    collection.flush()
    var before = load_manifest(path, 1)
    var sidecar_name = before.hnsw_name.value().copy()
    collection.compact()
    var after = load_manifest(path, 1)
    assert_equal(after.format_version, 3)
    assert_equal(after.generation, before.generation + UInt64(1))
    assert_equal(after.hnsw_name.value(), sidecar_name)
    assert_equal(len(after.segments), 1)
    assert_true(path_exists(path + "/" + sidecar_name))
    collection.close()


def test_same_sequence_v3_downgrade_cleans_exact_sidecar_after_wals() raises:
    var path = String("/tmp/akasha-task22-same-sequence-downgrade")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(1, 81):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    var before = load_manifest(path, 1)
    var old_sidecar = before.hnsw_name.value().copy()
    write_file_sync(path + "/hnsw-user.bin", [UInt8(9)])
    append_wal(
        path + "/wal.bin", 1, WalRecord.upsert(80, 80, [80.0])
    )
    append_sparse_wal(
        path + "/sparse.wal",
        SparseWalRecord.upsert(80, 80, [SparseElement(80, 1.0)]),
    )
    collection._hnsw_checkpoint_was_hit = False
    collection._hnsw_sidecar_max_bytes_for_test = UInt64(160)

    collection.flush()

    var after = load_manifest(path, 1)
    assert_equal(after.format_version, 2)
    assert_equal(after.generation, before.generation + UInt64(1))
    assert_equal(len(read_file_bytes(path + "/wal.bin")), 0)
    assert_equal(len(read_file_bytes(path + "/sparse.wal")), 0)
    assert_false(path_exists(path + "/" + old_sidecar))
    assert_true(path_exists(path + "/hnsw-user.bin"))
    collection.close()


def test_same_sequence_downgrade_keeps_old_sidecar_until_sparse_wal_rotates(
) raises:
    var path = String("/tmp/akasha-task22-same-sequence-order")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(1, 81):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    var before = load_manifest(path, 1)
    var old_sidecar = before.hnsw_name.value().copy()
    append_wal(
        path + "/wal.bin", 1, WalRecord.upsert(80, 80, [80.0])
    )
    collection._hnsw_checkpoint_was_hit = False
    collection._hnsw_sidecar_max_bytes_for_test = UInt64(160)
    remove_file_if_exists(path + "/sparse.wal")
    ensure_directory(path + "/sparse.wal")

    with assert_raises():
        collection.flush()

    var after = load_manifest(path, 1)
    var dense_wal_length = len(read_file_bytes(path + "/wal.bin"))
    var old_sidecar_exists = path_exists(path + "/" + old_sidecar)
    remove_file_if_exists(path + "/sparse.wal.tmp")
    _remove_empty_directory(path + "/sparse.wal")
    collection.close()
    assert_equal(after.format_version, 2)
    assert_equal(dense_wal_length, 0)
    assert_true(old_sidecar_exists)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
