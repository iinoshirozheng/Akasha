from akasha import PersistentCollection, SparseElement
from akasha.storage.filesystem import (
    atomic_replace,
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.operations import inspect_storage, restore_storage
from akasha.storage.manifest import load_manifest
from std.os import listdir
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(path: String) raises:
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)


def _source(path: String) raises -> PersistentCollection:
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(1, 11):
        collection.upsert(id, [Float32(id)])
        collection.upsert_sparse(id, [SparseElement(id, Float32(id))])
    collection.flush()
    for id in range(11, 21):
        collection.upsert(id, [Float32(id)])
    collection.rebuild_hnsw()
    return collection^


def _assert_not_a_backup(target: String, restored: String) raises:
    with assert_raises():
        _ = inspect_storage(target, 1)
    _reset(restored)
    with assert_raises():
        _ = restore_storage(target, restored, 1)
    assert_false(path_exists(restored + "/manifest.bin"))


def _assert_restores_all(target: String, restored: String) raises:
    _reset(restored)
    _ = restore_storage(target, restored, 1)
    var reopened = PersistentCollection.open(restored, 1)
    assert_true(reopened._hnsw_checkpoint_was_hit)
    for id in range(1, 21):
        assert_equal(reopened.get(id).value().vector[0], Float32(id))
    for id in range(1, 11):
        assert_equal(
            reopened.search_sparse_dot([SparseElement(id, 1.0)], 1)[0].id, id
        )
    reopened.close()


def test_crash_before_backup_manifest_leaves_no_backup_and_retry_completes() raises:
    var source = String("/tmp/akasha-53-crash-backup-source")
    var target = String("/tmp/akasha-53-crash-backup-target")
    var restored = String("/tmp/akasha-53-crash-backup-restored")
    var collection = _source(source)
    _reset(target)
    var report = collection.backup_to(target)
    assert_equal(report.segment_count, 2)

    # Power loss after the identity and one file, with the next file torn in
    # its temp name and no manifest yet.
    remove_file_if_exists(target + "/manifest.bin")
    var torn = report.segment_names[1]
    var bytes = read_file_bytes(target + "/" + torn)
    _ = bytes.pop()
    write_file_sync(target + "/" + torn + ".tmp", bytes)
    remove_file_if_exists(target + "/" + torn)
    remove_file_if_exists(target + "/" + report.sparse_names[1])
    _assert_not_a_backup(target, restored)

    # The retry overwrites the leftovers and verifies every file again.
    assert_equal(collection.backup_to(target).generation, report.generation)
    assert_false(path_exists(target + "/" + torn + ".tmp"))
    collection.close()
    _assert_restores_all(target, restored)


def test_crash_before_manifest_rename_leaves_no_backup() raises:
    var source = String("/tmp/akasha-53-crash-manifest-source")
    var target = String("/tmp/akasha-53-crash-manifest-target")
    var restored = String("/tmp/akasha-53-crash-manifest-restored")
    var collection = _source(source)
    _reset(target)
    var report = collection.backup_to(target)

    # Every file and the manifest temp are durable; the rename never ran.
    atomic_replace(target + "/manifest.bin", target + "/manifest.bin.tmp")
    _assert_not_a_backup(target, restored)

    assert_equal(collection.backup_to(target).generation, report.generation)
    assert_true(path_exists(target + "/manifest.bin"))
    collection.close()
    _assert_restores_all(target, restored)


def test_crash_during_hnsw_copy_leaves_no_backup_and_retry_completes() raises:
    var source = String("/tmp/akasha-56-crash-backup-hnsw-source")
    var target = String("/tmp/akasha-56-crash-backup-hnsw-target")
    var restored = String("/tmp/akasha-56-crash-backup-hnsw-restored")
    var collection = _source(source)
    _reset(target)
    var report = collection.backup_to(target)
    var manifest = load_manifest(target, 1)
    var name = manifest.hnsw_name.value().copy()
    var bytes = read_file_bytes(target + "/" + name)
    _ = bytes.pop()
    remove_file_if_exists(target + "/manifest.bin")
    write_file_sync(target + "/" + name + ".tmp", bytes)
    remove_file_if_exists(target + "/" + name)
    _assert_not_a_backup(target, restored)
    assert_equal(collection.backup_to(target).generation, report.generation)
    assert_false(path_exists(target + "/" + name + ".tmp"))
    collection.close()
    _reset(source)
    _assert_restores_all(target, restored)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
