from akasha import (
    CollectionConfig,
    DocumentField,
    MetricKind,
    PayloadValue,
    PersistentCollection,
    SparseElement,
)
from akasha.storage.collection_config import load_collection_config
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
        "collection.bin",
        "collection.bin.tmp",
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


def test_backup_and_restore_preserve_non_default_collection_identity() raises:
    var source = String("/tmp/akasha-phase15-ops-config-source")
    var backup = String("/tmp/akasha-phase15-ops-config-backup")
    var restored = String("/tmp/akasha-phase15-ops-config-restored")
    _reset(source)
    _reset(backup)
    _reset(restored)

    var config = CollectionConfig.defaults(2)
    config.ann_metric = MetricKind.cosine()
    var collection = PersistentCollection.open_with_config(source, config)
    collection.upsert(1, [1.0, 0.0])
    collection.flush()
    _ = collection.backup_to(backup)
    collection.close()

    assert_true(path_exists(backup + "/collection.bin"))
    assert_equal(load_collection_config(backup), config)
    _ = restore_storage(backup, restored, 2)
    assert_equal(load_collection_config(restored), config)

    var reopened = PersistentCollection.open_with_config(restored, config)
    assert_equal(reopened.collection_config(), config)
    assert_equal(reopened.get(1).value().vector[0], Float32(1.0))
    reopened.close()


def test_restore_rejects_wal_state_and_active_empty_target() raises:
    var source = String("/tmp/akasha-phase15-ops-wal-source")
    var backup = String("/tmp/akasha-phase15-ops-wal-backup")
    var target = String("/tmp/akasha-phase15-ops-wal-target")
    var sparse_target = String("/tmp/akasha-phase15-ops-sparse-wal-target")
    var active_target = String("/tmp/akasha-phase15-ops-active-target")
    _reset(source)
    _reset(backup)
    _reset(target)
    _reset(sparse_target)
    _reset(active_target)

    var source_collection = PersistentCollection.open(source, 2)
    source_collection.upsert(100, [1.0, 0.0])
    source_collection.flush()
    _ = source_collection.backup_to(backup)
    source_collection.close()

    # A WAL-only collection has no committed manifest but is authoritative.
    var target_collection = PersistentCollection.open(target, 2)
    target_collection.upsert(7, [0.0, 1.0])
    target_collection.close()
    assert_false(path_exists(target + "/manifest.bin"))
    assert_true(path_exists(target + "/wal.bin"))

    with assert_raises():
        _ = restore_storage(backup, target, 2)
    assert_false(path_exists(target + "/manifest.bin"))

    var reopened = PersistentCollection.open(target, 2)
    assert_true(Bool(reopened.get(7)))
    assert_false(Bool(reopened.get(100)))
    reopened.close()

    # Reject sparse state independently, before inspecting or copying it.
    write_file_sync(sparse_target + "/sparse.wal", [UInt8(0xA5)])
    with assert_raises():
        _ = restore_storage(backup, sparse_target, 2)
    assert_false(path_exists(sparse_target + "/manifest.bin"))
    assert_equal(read_file_bytes(sparse_target + "/sparse.wal")[0], UInt8(0xA5))

    # The state check and manifest publication must share the writer lock.
    var active = PersistentCollection.open(active_target, 2)
    assert_false(path_exists(active_target + "/manifest.bin"))
    assert_false(path_exists(active_target + "/wal.bin"))
    with assert_raises():
        _ = restore_storage(backup, active_target, 2)
    assert_false(path_exists(active_target + "/manifest.bin"))
    active.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
