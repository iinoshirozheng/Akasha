from akasha import PersistentCollection, SparseElement
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from max.algorithm import parallelize
from std.atomic import Atomic
from std.ffi import c_int, external_call
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


def _job_outputs(path: String) raises -> List[String]:
    var outputs = List[String]()
    for name in listdir(path):
        if name.startswith("segment-compact-") or name.startswith(
            "sparse-compact-"
        ):
            outputs.append(name)
    return outputs^


def _set_mode(path: String, mode: Int) raises:
    var owned_path = path
    var result = external_call["chmod", c_int](
        owned_path.as_c_string_slice().unsafe_ptr(), c_int(mode)
    )
    if result != 0:
        raise Error("chmod failed")


def _two_segment_collection(path: String) raises -> PersistentCollection:
    """Commit a base and a delta; id 1 is deleted by the delta."""
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
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


def _assert_committed_records(collection: PersistentCollection) raises:
    assert_false(Bool(collection.get(1)))
    for id in range(2, 41):
        var record = collection.get(id)
        assert_true(Bool(record))
        assert_equal(record.value().vector[0], Float32(id))
        var sparse = collection.search_sparse_dot([SparseElement(id, 1.0)], 1)
        assert_equal(len(sparse), 1)
        assert_equal(sparse[0].id, id)


def _assert_disk_generation(
    collection: PersistentCollection, path: String
) raises:
    var snapshot = collection.snapshot()
    assert_equal(snapshot.generation(), load_manifest(path, 1).generation)
    snapshot.close()


def test_compact_publishes_one_job_unique_base_at_disk_generation() raises:
    var path = String("/tmp/akasha-51-compaction-publish")
    var collection = _two_segment_collection(path)
    var before = load_manifest(path, 1)

    collection.compact()

    var after = load_manifest(path, 1)
    assert_equal(after.generation, before.generation + 1)
    assert_equal(after.last_sequence, before.last_sequence)
    assert_equal(len(after.segments), 1)
    assert_true(after.segments[0].name.startswith("segment-compact-"))
    assert_true(after.segments[0].sparse_name.startswith("sparse-compact-"))
    for index in range(len(before.segments)):
        assert_false(path_exists(path + "/" + before.segments[index].name))
        assert_false(
            path_exists(path + "/" + before.segments[index].sparse_name)
        )
    assert_equal(collection.compaction_attempts(), 1)
    assert_equal(collection.compaction_conflicts(), 0)
    _assert_disk_generation(collection, path)
    _assert_committed_records(collection)
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    _assert_committed_records(reopened)
    reopened.close()


def test_writes_between_capture_and_publish_keep_their_wal_tail() raises:
    var path = String("/tmp/akasha-51-compaction-wal-tail")
    var collection = _two_segment_collection(path)
    var inputs = collection._begin_compaction()
    assert_true(Bool(inputs))
    var captured = inputs.value().manifest.last_sequence

    # The writer lock is free while the job is outstanding.
    collection.upsert(41, [41.0])
    collection.upsert_sparse(41, [SparseElement(41, 41.0)])
    var output = collection._build_compaction(inputs.value())
    collection.upsert(42, [42.0])
    collection.delete(2)
    assert_true(collection._finish_compaction(inputs.value(), output))

    var committed = load_manifest(path, 1)
    assert_equal(committed.last_sequence, captured)
    assert_equal(committed.segments[0].name, output.segment_name)
    assert_equal(collection.last_sequence(), captured + 4)
    assert_false(Bool(collection.get(2)))
    assert_equal(collection.get(42).value().vector[0], 42.0)
    _assert_disk_generation(collection, path)
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.last_sequence(), captured + 4)
    assert_false(Bool(reopened.get(1)))
    assert_false(Bool(reopened.get(2)))
    for id in range(3, 43):
        assert_equal(reopened.get(id).value().vector[0], Float32(id))
    var sparse = reopened.search_sparse_dot([SparseElement(41, 1.0)], 1)
    assert_equal(sparse[0].id, 41)
    reopened.close()


def test_writers_proceed_while_compactions_build() raises:
    var path = String("/tmp/akasha-51-compaction-concurrent-writers")
    var collection = _two_segment_collection(path)
    var failures = Atomic[DType.int64](0)

    def write_or_compact(task: Int) {mut collection, mut failures}:
        try:
            if task == 0:
                for _ in range(4):
                    collection.compact()
                return
            for offset in range(50):
                var id = 1000 * task + offset
                collection.upsert(id, [Float32(id)])
        except:
            _ = failures.fetch_add(1)

    parallelize(write_or_compact, 4, 4)

    assert_equal(failures.load(), 0)
    assert_equal(collection.compaction_conflicts(), 0)
    _assert_disk_generation(collection, path)
    var expected = collection.last_sequence()
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.last_sequence(), expected)
    _assert_committed_records(reopened)
    for task in range(1, 4):
        for offset in range(50):
            var id = 1000 * task + offset
            assert_equal(reopened.get(id).value().vector[0], Float32(id))
    reopened.close()


def test_concurrent_flush_conflict_keeps_newer_manifest() raises:
    var path = String("/tmp/akasha-51-compaction-conflict")
    var collection = _two_segment_collection(path)
    var captured = load_manifest(path, 1)
    var inputs = collection._begin_compaction()
    var output = collection._build_compaction(inputs.value())
    assert_true(path_exists(path + "/" + output.segment_name))
    assert_true(path_exists(path + "/" + output.sparse_name))

    collection.upsert(41, [41.0])
    collection.flush()
    var newer = read_file_bytes(path + "/manifest.bin")

    assert_false(collection._finish_compaction(inputs.value(), output))
    assert_true(read_file_bytes(path + "/manifest.bin") == newer)
    assert_false(path_exists(path + "/" + output.segment_name))
    assert_false(path_exists(path + "/" + output.sparse_name))
    for index in range(len(captured.segments)):
        assert_true(path_exists(path + "/" + captured.segments[index].name))
    assert_equal(collection.compaction_conflicts(), 1)
    _assert_disk_generation(collection, path)

    # A fresh attempt captures the newer manifest and publishes.
    collection.compact()
    assert_equal(len(load_manifest(path, 1).segments), 1)
    assert_equal(collection.compaction_attempts(), 2)
    assert_equal(collection.compaction_conflicts(), 1)
    _assert_disk_generation(collection, path)
    assert_equal(collection.get(41).value().vector[0], 41.0)
    collection.close()


def test_retries_stay_bounded_while_flushes_race() raises:
    var path = String("/tmp/akasha-51-compaction-flush-race")
    var collection = _two_segment_collection(path)
    var failures = Atomic[DType.int64](0)
    var exhausted = Atomic[DType.int64](0)

    def flush_or_compact(
        task: Int,
    ) {mut collection, mut failures, mut exhausted}:
        if task == 0:
            for _ in range(8):
                try:
                    collection.compact()
                except error:
                    if "retry budget" in String(error):
                        _ = exhausted.fetch_add(1)
                    else:
                        _ = failures.fetch_add(1)
            return
        try:
            for offset in range(200):
                var id = 1000 + offset
                collection.upsert(id, [Float32(id)])
                collection.flush()
        except:
            _ = failures.fetch_add(1)

    parallelize(flush_or_compact, 2, 2)

    assert_equal(failures.load(), 0)
    var attempts = collection.compaction_attempts()
    var conflicts = collection.compaction_conflicts()
    assert_true(attempts <= 8 * 4)
    assert_true(conflicts >= Int(exhausted.load()) * 4)
    assert_true(attempts - conflicts <= 8 - Int(exhausted.load()))
    _assert_disk_generation(collection, path)
    var expected = collection.last_sequence()
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.last_sequence(), expected)
    _assert_committed_records(reopened)
    for offset in range(200):
        var id = 1000 + offset
        assert_equal(reopened.get(id).value().vector[0], Float32(id))
    reopened.close()


def test_losing_job_pin_keeps_inputs_until_released() raises:
    var path = String("/tmp/akasha-51-compaction-two-jobs")
    var collection = _two_segment_collection(path)
    var captured = load_manifest(path, 1)
    var first = collection._begin_compaction()
    var second = collection._begin_compaction()
    assert_equal(
        first.value().manifest.generation, second.value().manifest.generation
    )
    var first_output = collection._build_compaction(first.value())
    var second_output = collection._build_compaction(second.value())
    assert_true(first_output.segment_name != second_output.segment_name)
    assert_true(first_output.sparse_name != second_output.sparse_name)

    assert_true(collection._finish_compaction(first.value(), first_output))
    # The second job still leases the captured inputs.
    for index in range(len(captured.segments)):
        assert_true(path_exists(path + "/" + captured.segments[index].name))
        assert_true(
            path_exists(path + "/" + captured.segments[index].sparse_name)
        )

    assert_false(collection._finish_compaction(second.value(), second_output))
    assert_false(path_exists(path + "/" + second_output.segment_name))
    assert_false(path_exists(path + "/" + second_output.sparse_name))
    assert_true(path_exists(path + "/" + first_output.segment_name))
    assert_true(path_exists(path + "/" + first_output.sparse_name))

    # With the last lease gone, the next checkpoint reclaims the inputs.
    collection.flush()
    for index in range(len(captured.segments)):
        assert_false(path_exists(path + "/" + captured.segments[index].name))
        assert_false(
            path_exists(path + "/" + captured.segments[index].sparse_name)
        )
    _assert_committed_records(collection)
    collection.close()


def test_old_snapshot_keeps_reading_and_leases_replaced_inputs() raises:
    var path = String("/tmp/akasha-51-compaction-old-snapshot")
    var collection = _two_segment_collection(path)
    var captured = load_manifest(path, 1)
    var snapshot = collection.snapshot()

    collection.compact()
    collection.upsert(41, [41.0])

    assert_equal(snapshot.generation(), captured.generation)
    assert_equal(len(snapshot.search_dot([1.0], 64)), 39)
    for index in range(len(captured.segments)):
        assert_true(path_exists(path + "/" + captured.segments[index].name))
    snapshot.close()
    _ = collection.maintenance()
    for index in range(len(captured.segments)):
        assert_false(path_exists(path + "/" + captured.segments[index].name))
    collection.close()


def test_checksum_failure_keeps_old_generation() raises:
    var path = String("/tmp/akasha-51-compaction-checksum")
    var collection = _two_segment_collection(path)
    var manifest_bytes = read_file_bytes(path + "/manifest.bin")
    var captured = load_manifest(path, 1)
    var victim = path + "/" + captured.segments[1].name
    var original = read_file_bytes(victim)
    var corrupted = original.copy()
    corrupted[len(corrupted) // 2] ^= 0xFF
    write_file_sync(victim, corrupted)
    var pins = collection._pins[].active_count()

    with assert_raises():
        collection.compact()

    assert_true(read_file_bytes(path + "/manifest.bin") == manifest_bytes)
    assert_equal(len(_job_outputs(path)), 0)
    assert_equal(collection._pins[].active_count(), pins)
    assert_equal(collection.compaction_conflicts(), 0)
    _assert_committed_records(collection)
    _assert_disk_generation(collection, path)
    collection.close()

    write_file_sync(victim, original)
    var reopened = PersistentCollection.open(path, 1)
    _assert_committed_records(reopened)
    reopened.close()


def test_output_io_failure_keeps_old_generation() raises:
    var path = String("/tmp/akasha-51-compaction-io")
    var collection = _two_segment_collection(path)
    var manifest_bytes = read_file_bytes(path + "/manifest.bin")
    var pins = collection._pins[].active_count()
    var inputs = collection._begin_compaction()

    _set_mode(path, 0o555)
    var failed = False
    try:
        _ = collection._build_compaction(inputs.value())
    except:
        failed = True
    _set_mode(path, 0o755)

    assert_true(failed)
    assert_true(read_file_bytes(path + "/manifest.bin") == manifest_bytes)
    assert_equal(len(_job_outputs(path)), 0)
    assert_equal(collection._pins[].active_count(), pins)
    collection.upsert(41, [41.0])
    collection.flush()
    _assert_committed_records(collection)
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    _assert_committed_records(reopened)
    assert_equal(reopened.get(41).value().vector[0], 41.0)
    reopened.close()


def test_close_before_publish_cancels_and_discards_output() raises:
    var path = String("/tmp/akasha-51-compaction-cancel")
    var collection = _two_segment_collection(path)
    var manifest_bytes = read_file_bytes(path + "/manifest.bin")
    var inputs = collection._begin_compaction()
    var output = collection._build_compaction(inputs.value())
    collection.close()

    with assert_raises(contains="collection is closed"):
        _ = collection._finish_compaction(inputs.value(), output)

    assert_true(read_file_bytes(path + "/manifest.bin") == manifest_bytes)
    assert_equal(len(_job_outputs(path)), 0)
    assert_equal(collection._pins[].active_count(), 0)
    var reopened = PersistentCollection.open(path, 1)
    _assert_committed_records(reopened)
    reopened.close()


def test_restart_removes_unpublished_outputs_but_keeps_leased_inputs() raises:
    var path = String("/tmp/akasha-51-compaction-orphans")
    var collection = _two_segment_collection(path)
    collection.compact()
    var compacted = load_manifest(path, 1)
    var leased = compacted.segments[0].name.copy()
    var leased_sparse = compacted.segments[0].sparse_name.copy()
    var snapshot = collection.snapshot()
    collection.upsert(41, [41.0])
    collection.flush()
    collection.compact()
    # The snapshot still leases the replaced compaction output.
    assert_true(path_exists(path + "/" + leased))

    # A crash after output fsync leaves durable but unpublished job files.
    collection.upsert(42, [42.0])
    var inputs = collection._begin_compaction()
    var orphan = collection._build_compaction(inputs.value())
    collection._pins[].unpin(inputs.value().manifest.generation)
    collection.close()
    assert_true(path_exists(path + "/" + orphan.segment_name))

    var reopened = PersistentCollection.open(path, 1)
    assert_false(path_exists(path + "/" + orphan.segment_name))
    assert_false(path_exists(path + "/" + orphan.sparse_name))
    assert_true(path_exists(path + "/" + leased))
    assert_true(path_exists(path + "/" + leased_sparse))
    assert_equal(len(snapshot.search_dot([1.0], 64)), 39)
    snapshot.close()
    _assert_committed_records(reopened)
    assert_equal(reopened.get(42).value().vector[0], 42.0)
    reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
