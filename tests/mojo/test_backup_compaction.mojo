from akasha import PersistentCollection
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    remove_file_if_exists,
)
from akasha.storage.manifest import load_manifest
from akasha.storage.operations import copy_checkpoint
from std.os import listdir
from std.testing import assert_equal, assert_true, TestSuite


def _reset(path: String) raises:
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)


def test_backup_pins_pre_compaction_files_without_a_worker() raises:
    var path = String("/tmp/akasha-backup-inline-compaction-source")
    var target = String("/tmp/akasha-backup-inline-compaction-target")
    _reset(path)
    _reset(target)
    var collection = PersistentCollection.open(
        path, 1, maintenance_library_path="/missing/akasha-worker.so"
    )
    for id in range(1, 5):
        collection.upsert(id, [Float32(id)])
        collection.flush()
    collection.upsert(5, [5.0])
    # Capture crosses the L0 threshold. Its synchronous compaction uses the
    # same unlocked job as public compact, and must preserve the backup pin.
    var captured = collection._begin_backup()
    var current = load_manifest(path, 1)
    assert_equal(len(current.segments), 1)
    assert_true(current.segments[0].name.startswith("segment-compact-"))
    assert_equal(len(captured.manifest.segments), 5)
    assert_equal(collection._pins[].active_count(), 1)
    for index in range(len(captured.manifest.segments)):
        ref segment = captured.manifest.segments[index]
        assert_true(path_exists(path + "/" + segment.name))
        assert_true(path_exists(path + "/" + segment.sparse_name))
    copy_checkpoint(path, target, captured)
    collection._end_backup(captured)
    assert_equal(collection._pins[].active_count(), 0)
    collection.flush()
    collection.close()
    _reset(path)
    var restored = PersistentCollection.open(target, 1)
    assert_equal(restored.last_sequence(), UInt64(5))
    for id in range(1, 6):
        assert_equal(restored.get(id).value().vector[0], Float32(id))
    restored.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
