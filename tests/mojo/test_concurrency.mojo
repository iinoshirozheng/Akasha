from akasha import BatchMutation, PersistentCollection
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from max.algorithm import parallelize
from std.atomic import Atomic
from std.testing import assert_equal, TestSuite


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/sparse.wal")
    remove_file_if_exists(directory + "/sparse.wal.tmp")


def test_concurrent_batch_writers_serialize_sequence_and_recovery() raises:
    var path = String("/tmp/akasha-phase11-concurrent-writers")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var failures = Atomic[DType.int64](0)

    def write_batch(worker: Int) {mut collection, mut failures}:
        try:
            var mutations = List[BatchMutation]()
            for offset in range(4):
                var id = worker * 100 + offset
                mutations.append(BatchMutation.upsert(id, [Float32(id + 1)]))
            _ = collection.apply_batch(mutations)
        except:
            _ = failures.fetch_add(1)

    parallelize(write_batch, 8, 4)

    assert_equal(failures.load(), 0)
    assert_equal(collection.last_sequence(), UInt64(32))
    assert_equal(collection.metadata_live_count(), 32)
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.last_sequence(), UInt64(32))
    assert_equal(reopened.metadata_live_count(), 32)
    reopened.close()


def test_concurrent_snapshot_capture_observes_only_batch_boundaries() raises:
    var path = String("/tmp/akasha-phase11-concurrent-snapshots")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var failures = Atomic[DType.int64](0)
    var sequences = List[UInt64](length=4, fill=0)
    var counts = List[Int](length=4, fill=0)

    def write_or_snapshot(
        task: Int,
    ) {mut collection, mut failures, mut sequences, mut counts}:
        try:
            if task < 4:
                var mutations = List[BatchMutation]()
                for offset in range(4):
                    var id = task * 100 + offset
                    mutations.append(
                        BatchMutation.upsert(id, [Float32(id + 1)])
                    )
                _ = collection.apply_batch(mutations)
                return
            var snapshot_index = task - 4
            var snapshot = collection.snapshot()
            sequences[snapshot_index] = snapshot.last_sequence()
            counts[snapshot_index] = len(snapshot.search_dot([1.0], 64))
            snapshot.close()
        except:
            _ = failures.fetch_add(1)

    parallelize(write_or_snapshot, 8, 4)

    assert_equal(failures.load(), 0)
    assert_equal(collection.last_sequence(), UInt64(16))
    for index in range(4):
        assert_equal(sequences[index] % 4, UInt64(0))
        assert_equal(UInt64(counts[index]), sequences[index])
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
