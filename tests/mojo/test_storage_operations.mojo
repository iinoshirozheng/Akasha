from akasha import DocumentField, PayloadValue, PersistentCollection, SparseElement
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.operations import backup_storage, inspect_storage, restore_storage
from std.testing import assert_equal, assert_false, assert_raises, assert_true, TestSuite


def _reset(path: String) raises:
    ensure_directory(path)
    for name in [
        "manifest.bin",
        "manifest.bin.tmp",
        "wal.bin",
        "sparse.wal",
        "segment-base-2.bin",
        "segment-base-4.bin",
        "sparse-base-2.bin",
        "sparse-base-4.bin",
    ]:
        remove_file_if_exists(path + "/" + name)


def test_inspection_backup_and_restore_validate_committed_generation() raises:
    var source = String("/tmp/akasha-phase15-ops-source")
    var backup = String("/tmp/akasha-phase15-ops-backup")
    var restored = String("/tmp/akasha-phase15-ops-restored")
    _reset(source)
    _reset(backup)
    _reset(restored)
    var collection = PersistentCollection.open(source, 2)
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("backup")))
    collection.upsert_document(1, [1.0, 0.0], fields^)
    collection.upsert(2, [0.0, 1.0])
    collection.upsert_sparse(1, [SparseElement(7, 2.0)])
    collection.flush()

    var report = inspect_storage(source, 2)
    assert_equal(report.live_points, 2)
    assert_equal(report.segment_count, 1)
    assert_true(report.valid)
    var copied = collection.backup_to(backup)
    assert_equal(copied.generation, report.generation)
    assert_true(path_exists(backup + "/manifest.bin"))
    collection.close()

    var restore = restore_storage(backup, restored, 2)
    assert_equal(restore.last_sequence, report.last_sequence)
    var reopened = PersistentCollection.open(restored, 2)
    assert_equal(reopened.search_dot([1.0, 0.0], 2)[0].id, 1)
    assert_equal(
        reopened.get(1).value().get_field("chunk").value().as_string(),
        "backup",
    )
    assert_equal(reopened.search_sparse_dot([SparseElement(7, 1.0)], 1)[0].id, 1)
    reopened.close()


def test_corrupt_source_never_publishes_backup_manifest() raises:
    var source = String("/tmp/akasha-phase15-ops-corrupt")
    var target = String("/tmp/akasha-phase15-ops-corrupt-target")
    _reset(source)
    _reset(target)
    var collection = PersistentCollection.open(source, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    collection.close()

    var report = inspect_storage(source, 1)
    var path = source + "/" + report.segment_names[0]
    var bytes = read_file_bytes(path)
    bytes[16] ^= UInt8(1)
    write_file_sync(path, bytes)

    with assert_raises():
        _ = backup_storage(source, target, 1)
    assert_false(path_exists(target + "/manifest.bin"))
    with assert_raises():
        _ = inspect_storage(source, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
