from akasha import CollectionConfig, PersistentCollection
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from std.testing import assert_equal, assert_false, assert_true, TestSuite


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
