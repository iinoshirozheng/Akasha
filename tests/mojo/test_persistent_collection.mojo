from akasha import PersistentCollection
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import (
    load_manifest,
    Manifest,
    publish_manifest,
    SegmentDescriptor,
)
from akasha.storage.memtable import MemTable, MemTableEntry
from akasha.storage.segment import (
    SEGMENT_KIND_BASE,
    SEGMENT_KIND_DELTA,
    write_segment_v3,
)
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    TestSuite,
)


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/segment-stray.bin")
    remove_file_if_exists(directory + "/segment-base-2.bin")
    remove_file_if_exists(directory + "/segment-delta-4.bin")
    remove_file_if_exists(directory + "/segment-delta-6.bin")
    for sequence in range(11):
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin.tmp"
        )
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin.tmp"
        )
        remove_file_if_exists(
            directory + "/segment-delta-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-delta-" + String(sequence) + ".bin.tmp"
        )


def test_collection_upsert_replace_delete_and_exact_search() raises:
    var path = String("/tmp/akasha-phase3-collection-live")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(10, [1.0, 0.0])
    collection.upsert(20, [0.0, 1.0])
    collection.upsert(20, [2.0, 0.0])
    var query: List[Float32] = [1.0, 0.0]

    var dot = collection.search_dot(query, 2)
    var l2 = collection.search_l2(query, 2)
    var cosine = collection.search_cosine(query, 2)

    assert_equal(dot[0].id, 20)
    assert_almost_equal(dot[0].score, 2.0, atol=1.0e-6)
    assert_equal(l2[0].id, 10)
    assert_equal(cosine[0].id, 10)
    collection.delete(10)
    var after_delete = collection.search_dot(query, 2)
    assert_equal(len(after_delete), 1)
    assert_equal(after_delete[0].id, 20)


def test_wal_only_recovery() raises:
    var path = String("/tmp/akasha-phase3-collection-wal")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.upsert(2, [3.0])
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    var query: List[Float32] = [1.0]
    var results = reopened.search_dot(query, 2)

    assert_equal(len(results), 2)
    assert_equal(results[0].id, 2)
    assert_equal(reopened.last_sequence(), UInt64(2))


def test_flush_and_reopen_restores_complete_live_snapshot() raises:
    var path = String("/tmp/akasha-phase3-collection-flush")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1.0, 0.0])
    collection.upsert(2, [0.0, 1.0])
    collection.delete(1)
    collection.flush()
    collection.close()

    var reopened = PersistentCollection.open(path, 2)
    var query: List[Float32] = [0.0, 1.0]
    var results = reopened.search_dot(query, 3)

    assert_equal(len(results), 1)
    assert_equal(results[0].id, 2)
    assert_equal(reopened.last_sequence(), UInt64(3))


def test_reopen_combines_snapshot_with_newer_wal_records() raises:
    var path = String("/tmp/akasha-phase3-collection-mixed")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    collection.upsert(2, [2.0])
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    var query: List[Float32] = [1.0]
    var results = reopened.search_dot(query, 2)

    assert_equal(len(results), 2)
    assert_equal(results[0].id, 2)
    assert_equal(results[1].id, 1)
    assert_equal(reopened.last_sequence(), UInt64(2))


def test_existing_collection_rejects_dimension_mismatch() raises:
    var path = String("/tmp/akasha-phase3-collection-dimension")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1.0, 0.0])
    collection.flush()

    with assert_raises():
        _ = PersistentCollection.open(path, 3)


def test_collection_rejects_second_live_owner_and_reopens_after_close() raises:
    var path = String("/tmp/akasha-phase5-collection-owner")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)

    with assert_raises():
        _ = PersistentCollection.open(path, 1)

    collection.close()
    var reopened = PersistentCollection.open(path, 1)
    reopened.close()


def test_closed_collection_rejects_data_operations() raises:
    var path = String("/tmp/akasha-phase5-collection-closed")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.close()

    with assert_raises():
        collection.upsert(1, [1.0])
    with assert_raises():
        _ = collection.get(1)
    with assert_raises():
        _ = collection.search_dot([1.0], 1)
    with assert_raises():
        collection.delete(1)
    with assert_raises():
        collection.flush()


def test_flush_rotates_wal_and_reopen_uses_snapshot() raises:
    var path = String("/tmp/akasha-phase5-flush-rotates-wal")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [2.0])

    collection.flush()

    assert_equal(len(read_file_bytes(path + "/wal.bin")), 0)
    collection.close()
    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.get(1).value().vector[0], Float32(2.0))


def test_later_flush_appends_delta_and_preserves_referenced_base() raises:
    var path = String("/tmp/akasha-phase5-segment-reclaim")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    var stray: List[UInt8] = [1, 2, 3]
    write_file_sync(path + "/segment-stray.bin", stray)

    collection.delete(1)
    collection.upsert(2, [2.0])
    collection.flush()

    var manifest = load_manifest(path, 1)
    assert_equal(manifest.format_version, 2)
    assert_equal(manifest.generation, UInt64(2))
    assert_equal(len(manifest.segments), 2)
    assert_equal(manifest.segments[0].level, 1)
    assert_equal(manifest.segments[1].level, 0)
    assert_equal(path_exists(path + "/segment-base-1.bin"), True)
    assert_equal(path_exists(path + "/segment-delta-3.bin"), True)
    assert_equal(path_exists(path + "/segment-stray.bin"), True)
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    assert_equal(Bool(reopened.get(1)), False)
    assert_equal(reopened.get(2).value().vector[0], Float32(2.0))
    remove_file_if_exists(path + "/segment-stray.bin")


def test_recovery_skips_retained_pre_checkpoint_wal() raises:
    var path = String("/tmp/akasha-phase5-checkpoint-crash-window")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(7, [3.0])
    var old_wal = read_file_bytes(path + "/wal.bin")
    collection.flush()
    write_file_sync(path + "/wal.bin", old_wal)
    collection.close()

    var recovered = PersistentCollection.open(path, 1)
    var result = recovered.search_dot([1.0], 2)
    assert_equal(len(result), 1)
    assert_equal(result[0].id, 7)
    assert_equal(recovered.last_sequence(), UInt64(1))


def test_recovery_applies_base_and_deltas_in_manifest_sequence_order() raises:
    var path = String("/tmp/akasha-phase10-multi-segment-recovery")
    _reset(path)

    var base = MemTable(1)
    base.apply_upsert(1, 1, [1.0])
    base.apply_upsert(2, 2, [2.0])
    var base_entries = base.live_entries()
    var base_checksum = write_segment_v3(
        path + "/segment-base-2.bin",
        1,
        SEGMENT_KIND_BASE,
        0,
        2,
        base_entries,
    )

    var first_delta = List[MemTableEntry]()
    first_delta.append(MemTableEntry(1, 3, True, List[Float32]()))
    first_delta.append(MemTableEntry(2, 4, False, [4.0]))
    var first_checksum = write_segment_v3(
        path + "/segment-delta-4.bin",
        1,
        SEGMENT_KIND_DELTA,
        3,
        4,
        first_delta,
    )

    var second_delta = List[MemTableEntry]()
    second_delta.append(MemTableEntry(1, 5, False, [5.0]))
    second_delta.append(MemTableEntry(3, 6, False, [6.0]))
    var second_checksum = write_segment_v3(
        path + "/segment-delta-6.bin",
        1,
        SEGMENT_KIND_DELTA,
        5,
        6,
        second_delta,
    )

    var descriptors = List[SegmentDescriptor]()
    descriptors.append(
        SegmentDescriptor(1, 0, 2, base_checksum, "segment-base-2.bin")
    )
    descriptors.append(
        SegmentDescriptor(0, 3, 4, first_checksum, "segment-delta-4.bin")
    )
    descriptors.append(
        SegmentDescriptor(0, 5, 6, second_checksum, "segment-delta-6.bin")
    )
    var manifest = Manifest.with_segments(1, 3, 6, descriptors^)
    publish_manifest(path, manifest)

    var collection = PersistentCollection.open(path, 1)
    var results = collection.search_dot([1.0], 3)

    assert_equal(collection.last_sequence(), UInt64(6))
    assert_equal(len(results), 3)
    assert_equal(results[0].id, 3)
    assert_equal(results[1].id, 1)
    assert_equal(results[2].id, 2)
    assert_equal(collection.get(1).value().sequence, UInt64(5))
    assert_equal(collection.get(2).value().vector[0], Float32(4.0))


def test_full_compaction_replaces_segments_and_preserves_query_results() raises:
    var path = String("/tmp/akasha-phase10-full-compaction")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    collection.upsert(1, [4.0])
    collection.upsert(2, [2.0])
    collection.flush()
    collection.delete(1)
    collection.upsert(3, [3.0])
    collection.flush()
    var stray: List[UInt8] = [9, 9]
    write_file_sync(path + "/segment-stray.bin", stray)
    var before = collection.search_dot([1.0], 3)
    var before_manifest = load_manifest(path, 1)
    assert_equal(len(before_manifest.segments), 3)

    collection.compact()

    var compacted = load_manifest(path, 1)
    var after = collection.search_dot([1.0], 3)
    assert_equal(compacted.generation, UInt64(4))
    assert_equal(len(compacted.segments), 1)
    assert_equal(compacted.segments[0].level, 1)
    assert_equal(compacted.segments[0].name, "segment-base-5.bin")
    assert_equal(path_exists(path + "/segment-base-1.bin"), False)
    assert_equal(path_exists(path + "/segment-delta-3.bin"), False)
    assert_equal(path_exists(path + "/segment-delta-5.bin"), False)
    assert_equal(path_exists(path + "/segment-stray.bin"), True)
    assert_equal(len(after), len(before))
    assert_equal(after[0].id, before[0].id)
    assert_equal(after[1].id, before[1].id)
    assert_equal(Bool(collection.get(1)), False)
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.search_dot([1.0], 3)[0].id, 3)
    assert_equal(Bool(reopened.get(1)), False)


def test_maintenance_compacts_at_default_level_zero_threshold() raises:
    var path = String("/tmp/akasha-phase10-maintenance-threshold")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    for id in range(2, 6):
        collection.upsert(id, [Float32(id)])
        collection.flush()

    assert_equal(collection.maintenance(), True)
    assert_equal(len(load_manifest(path, 1).segments), 1)
    assert_equal(collection.maintenance(), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
