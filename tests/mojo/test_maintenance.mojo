from akasha import PersistentCollection
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/sparse.wal")
    remove_file_if_exists(directory + "/sparse.wal.tmp")
    for sequence in range(64):
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-delta-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-delta-" + String(sequence) + ".bin"
        )


def _write_five_checkpoints(mut collection: PersistentCollection) raises:
    collection.upsert(1, [1.0])
    collection.flush()
    for id in range(2, 6):
        collection.upsert(id, [Float32(id)])
        collection.flush()


def test_background_worker_compacts_threshold_and_close_joins() raises:
    var path = String("/tmp/akasha-phase11-background-maintenance")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    assert_true(collection.background_maintenance_enabled())
    _write_five_checkpoints(collection)
    assert_true(collection.wait_for_maintenance())
    var manifest = load_manifest(path, 1)
    assert_equal(len(manifest.segments), 1)
    assert_equal(manifest.last_sequence, UInt64(5))
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    assert_equal(len(reopened.search_dot([1.0], 10)), 5)
    reopened.close()


def test_missing_worker_library_uses_synchronous_fallback() raises:
    var path = String("/tmp/akasha-phase11-maintenance-fallback")
    _reset(path)
    var collection = PersistentCollection.open(
        path,
        1,
        maintenance_library_path="/missing/libakasha-worker.so",
    )
    assert_false(collection.background_maintenance_enabled())
    _write_five_checkpoints(collection)
    var manifest = load_manifest(path, 1)
    assert_equal(len(manifest.segments), 1)
    assert_false(collection.wait_for_maintenance())
    collection.close()


def test_worker_failure_surfaces_on_wait_and_close_without_leaking_lock() raises:
    var path = String("/tmp/akasha-phase11-maintenance-failure")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    _ = collection.wait_for_maintenance()
    write_file_sync(path + "/manifest.bin", [UInt8(0), UInt8(1)])
    assert_true(collection.schedule_maintenance())
    with assert_raises():
        _ = collection.wait_for_maintenance()
    with assert_raises():
        collection.close()

    _reset(path)
    var reopened = PersistentCollection.open(path, 1)
    reopened.close()


def test_background_compaction_respects_snapshot_generation_pins() raises:
    var path = String("/tmp/akasha-phase11-maintenance-pins")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    var snapshot = collection.snapshot()
    for id in range(2, 6):
        collection.upsert(id, [Float32(id)])
        collection.flush()
    _ = collection.wait_for_maintenance()

    assert_true(path_exists(path + "/segment-base-1.bin"))
    assert_true(path_exists(path + "/sparse-base-1.bin"))
    assert_true(Bool(snapshot.get(1)))
    snapshot.close()
    _ = collection.maintenance()
    assert_false(path_exists(path + "/segment-base-1.bin"))
    assert_false(path_exists(path + "/sparse-base-1.bin"))
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
