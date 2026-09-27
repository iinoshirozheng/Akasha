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
from akasha.storage.manifest import load_manifest
from akasha.storage.operations import (
    copy_checkpoint,
    inspect_storage,
    restore_storage,
    StorageInspection,
)
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


def _two_segment_collection(
    path: String, config: CollectionConfig = CollectionConfig.defaults(1)
) raises -> PersistentCollection:
    """Commit a base and a delta; id 1 is deleted by the delta."""
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, config.copy())
    for id in range(1, 21):
        collection.upsert(id, [Float32(id)])
        collection.upsert_sparse(id, [SparseElement(id, Float32(id))])
    collection.flush()
    for id in range(21, 41):
        collection.upsert(id, [Float32(id)])
        collection.upsert_sparse(id, [SparseElement(id, Float32(id))])
    collection.delete(1)
    collection.flush()
    assert_equal(len(load_manifest(path, 1).segments), 2)
    return collection^


def _assert_same_report(
    actual: StorageInspection, expected: StorageInspection
) raises:
    assert_equal(actual.dimension, expected.dimension)
    assert_equal(actual.format_version, expected.format_version)
    assert_equal(actual.generation, expected.generation)
    assert_equal(actual.last_sequence, expected.last_sequence)
    assert_equal(actual.segment_count, expected.segment_count)
    assert_equal(actual.live_points, expected.live_points)
    assert_equal(actual.valid, expected.valid)
    assert_equal(actual.config_fingerprint, expected.config_fingerprint)
    assert_true(actual.segment_names == expected.segment_names)
    assert_true(actual.sparse_names == expected.sparse_names)


def _assert_file_copies(
    source: String, target: String, report: StorageInspection
) raises:
    for name in report.segment_names:
        assert_true(
            read_file_bytes(target + "/" + name)
            == read_file_bytes(source + "/" + name)
        )
    for name in report.sparse_names:
        assert_true(
            read_file_bytes(target + "/" + name)
            == read_file_bytes(source + "/" + name)
        )


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
    assert_equal(copied.live_points, 2)
    assert_true(path_exists(backup + "/manifest.bin"))
    _assert_same_report(inspect_storage(backup, 2), copied)
    _assert_file_copies(source, backup, copied)
    collection.close()

    # Copies own their inodes: rewriting a source file leaves the backup.
    var source_segment = source + "/" + copied.segment_names[0]
    var bytes = read_file_bytes(source_segment)
    bytes[16] ^= UInt8(1)
    write_file_sync(source_segment, bytes)
    _assert_same_report(inspect_storage(backup, 2), copied)

    var restore = restore_storage(backup, restored, 2)
    _assert_same_report(restore, copied)
    _assert_same_report(inspect_storage(restored, 2), restore)
    var reopened = PersistentCollection.open(restored, 2)
    assert_equal(reopened.search_dot([1.0, 0.0], 2)[0].id, 1)
    assert_equal(
        reopened.get(1).value().get_field("chunk").value().as_string(),
        "backup",
    )
    assert_equal(
        reopened.search_sparse_dot([SparseElement(7, 1.0)], 1)[0].id, 1
    )
    reopened.close()


def test_backup_copies_the_pinned_view_while_the_source_moves_on() raises:
    var source = String("/tmp/akasha-53-backup-race-source")
    var backup = String("/tmp/akasha-53-backup-race-backup")
    var restored = String("/tmp/akasha-53-backup-race-restored")
    _reset(backup)
    _reset(restored)
    # Every flush rebuilds the graph and commits an eligible sidecar.
    var config = CollectionConfig.defaults(1)
    config.m0 = config.m
    config.delta_max_points = 1
    var collection = _two_segment_collection(source, config)
    var checkpoint = collection._begin_backup()
    var captured = load_manifest(source, 1)
    assert_equal(checkpoint.manifest.generation, captured.generation)
    assert_true(Bool(captured.hnsw_name))

    # The source flushes and compacts past the captured generation.
    collection.upsert(41, [41.0])
    collection.flush()
    collection.compact()
    var newer = load_manifest(source, 1)
    assert_true(newer.generation > captured.generation)
    assert_equal(len(newer.segments), 1)
    assert_false(path_exists(source + "/" + captured.hnsw_name.value()))
    for index in range(len(captured.segments)):
        assert_true(path_exists(source + "/" + captured.segments[index].name))

    copy_checkpoint(source, backup, checkpoint)
    collection._end_backup(checkpoint)
    var report = checkpoint.report.copy()
    assert_equal(report.generation, captured.generation)
    assert_equal(report.last_sequence, captured.last_sequence)
    assert_equal(report.segment_count, 2)
    assert_equal(report.live_points, 39)
    _assert_same_report(inspect_storage(backup, 1), report)

    # The derived sidecar is omitted explicitly; the graph rebuilds on open.
    var copied = load_manifest(backup, 1)
    assert_false(Bool(copied.hnsw_name))
    assert_equal(copied.format_version, 2)
    assert_false(path_exists(backup + "/" + captured.hnsw_name.value()))

    # Without the lease, the next checkpoint reclaims the captured inputs.
    collection.upsert(42, [42.0])
    collection.flush()
    for index in range(len(captured.segments)):
        assert_false(path_exists(source + "/" + captured.segments[index].name))
    collection.close()
    _reset(source)

    _ = restore_storage(backup, restored, 1)
    var reopened = PersistentCollection.open_with_config(restored, config)
    assert_equal(reopened.last_sequence(), captured.last_sequence)
    assert_false(Bool(reopened.get(1)))
    assert_false(Bool(reopened.get(41)))
    for id in range(2, 41):
        assert_equal(reopened.get(id).value().vector[0], Float32(id))
        assert_equal(
            reopened.search_sparse_dot([SparseElement(id, 1.0)], 1)[0].id, id
        )
    assert_true(reopened.hnsw_available())
    assert_equal(reopened.search_l2_approx([40.0], 1, 40)[0].id, 40)
    reopened.close()


def test_backup_copy_is_exact_for_any_buffer_size() raises:
    var source = String("/tmp/akasha-53-backup-buffer-source")
    var collection = _two_segment_collection(source)
    var checkpoint = collection._begin_backup()
    for buffer_bytes in [1, 3, 4, 5, 7, 4096]:
        var target = String("/tmp/akasha-53-backup-buffer-") + String(
            buffer_bytes
        )
        _reset(target)
        copy_checkpoint(source, target, checkpoint, buffer_bytes)
        _assert_same_report(inspect_storage(target, 1), checkpoint.report)
        _assert_file_copies(source, target, checkpoint.report)
    var empty = String("/tmp/akasha-53-backup-buffer-0")
    _reset(empty)
    with assert_raises():
        copy_checkpoint(source, empty, checkpoint, 0)
    assert_false(path_exists(empty + "/manifest.bin"))
    collection._end_backup(checkpoint)
    collection.close()


def test_backup_rejects_corrupt_torn_or_mislabeled_source_files() raises:
    var source = String("/tmp/akasha-phase15-ops-corrupt")
    var target = String("/tmp/akasha-phase15-ops-corrupt-target")
    _reset(source)
    var collection = PersistentCollection.open(source, 1)
    collection.upsert(1, [1.0])
    collection.upsert_sparse(1, [SparseElement(3, 1.0)])
    collection.flush()

    var report = inspect_storage(source, 1)
    var names = [report.segment_names[0], report.sparse_names[0]]
    for name in names:
        var path = source + "/" + name
        var original = read_file_bytes(path)
        # A checksummed byte, the unchecksummed magic, then a torn tail.
        for damage in range(3):
            var damaged = original.copy()
            if damage == 0:
                damaged[16] ^= UInt8(1)
            elif damage == 1:
                damaged[0] ^= UInt8(1)
            else:
                _ = damaged.pop()
            write_file_sync(path, damaged)
            _reset(target)
            with assert_raises():
                _ = collection.backup_to(target)
            assert_false(path_exists(target + "/manifest.bin"))
            assert_false(path_exists(target + "/" + name))
        write_file_sync(path, original)

    _reset(target)
    var copied = collection.backup_to(target)
    _assert_same_report(copied, inspect_storage(target, 1))
    assert_true(copied.segment_names == report.segment_names)
    assert_true(copied.sparse_names == report.sparse_names)
    collection.close()


def test_backup_rejects_committed_wal_and_active_targets() raises:
    var source = String("/tmp/akasha-53-backup-targets-source")
    var committed = String("/tmp/akasha-53-backup-targets-committed")
    var wal_target = String("/tmp/akasha-53-backup-targets-wal")
    var active_target = String("/tmp/akasha-53-backup-targets-active")
    _reset(source)
    _reset(committed)
    _reset(wal_target)
    _reset(active_target)
    var collection = PersistentCollection.open(source, 2)
    collection.upsert(100, [1.0, 0.0])
    _ = collection.backup_to(committed)
    with assert_raises():
        _ = collection.backup_to(committed)

    var wal_collection = PersistentCollection.open(wal_target, 2)
    wal_collection.upsert(7, [0.0, 1.0])
    wal_collection.close()
    with assert_raises():
        _ = collection.backup_to(wal_target)
    assert_false(path_exists(wal_target + "/manifest.bin"))

    var active = PersistentCollection.open(active_target, 2)
    with assert_raises():
        _ = collection.backup_to(active_target)
    assert_false(path_exists(active_target + "/manifest.bin"))
    active.close()
    collection.close()


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
