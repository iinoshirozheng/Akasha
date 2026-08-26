from akasha import (
    BatchMutation,
    DocumentField,
    PayloadValue,
    PersistentCollection,
)
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    remove_file_if_exists,
)
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


def test_atomic_batch_applies_contiguous_mixed_mutations() raises:
    var path = String("/tmp/akasha-phase11-batch-mixed")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(9, [9.0, 0.0])
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("batch")))
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.upsert(1, [1.0, 0.0]))
    mutations.append(BatchMutation.document_upsert(2, [0.0, 2.0], fields^))
    mutations.append(BatchMutation.delete(9))

    var committed = collection.apply_batch(mutations)

    assert_equal(committed.first_sequence, UInt64(2))
    assert_equal(committed.last_sequence, UInt64(4))
    assert_equal(committed.count, 3)
    assert_equal(collection.last_sequence(), UInt64(4))
    assert_true(Bool(collection.get(1)))
    assert_equal(
        collection.get(2).value().get_field("chunk").value().as_string(),
        "batch",
    )
    assert_false(Bool(collection.get(9)))
    collection.close()


def test_batch_validation_failure_changes_no_sequence_wal_or_live_state() raises:
    var path = String("/tmp/akasha-phase11-batch-validation")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(7, [1.0, 1.0])
    var before_sequence = collection.last_sequence()
    var before_wal_size = len(read_file_bytes(path + "/wal.bin"))
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.upsert(8, [2.0, 2.0]))
    mutations.append(BatchMutation.upsert(9, [3.0]))

    with assert_raises():
        _ = collection.apply_batch(mutations)

    assert_equal(collection.last_sequence(), before_sequence)
    assert_equal(len(read_file_bytes(path + "/wal.bin")), before_wal_size)
    assert_false(Bool(collection.get(8)))
    assert_false(Bool(collection.get(9)))
    collection.close()


def test_batch_reopens_atomically_and_duplicate_id_uses_latest_mutation() raises:
    var path = String("/tmp/akasha-phase11-batch-reopen")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.upsert(1, [1.0]))
    mutations.append(BatchMutation.upsert(1, [2.0]))
    mutations.append(BatchMutation.upsert(2, [3.0]))
    _ = collection.apply_batch(mutations)
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.last_sequence(), UInt64(3))
    assert_equal(reopened.get(1).value().vector[0], Float32(2.0))
    assert_equal(reopened.get(1).value().sequence, UInt64(2))
    assert_equal(reopened.get(2).value().vector[0], Float32(3.0))
    reopened.close()


def test_batch_rejects_empty_input() raises:
    var path = String("/tmp/akasha-phase11-batch-empty")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var empty = List[BatchMutation]()
    with assert_raises():
        _ = collection.apply_batch(empty)
    assert_equal(collection.last_sequence(), UInt64(0))
    collection.close()


def test_snapshot_observes_batch_before_or_after_but_never_a_prefix() raises:
    var path = String("/tmp/akasha-phase11-batch-snapshot")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    var before = collection.snapshot()
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.upsert(2, [2.0]))
    mutations.append(BatchMutation.delete(1))
    mutations.append(BatchMutation.upsert(3, [3.0]))

    _ = collection.apply_batch(mutations)
    var after = collection.snapshot()

    assert_true(Bool(before.get(1)))
    assert_false(Bool(before.get(2)))
    assert_false(Bool(before.get(3)))
    assert_false(Bool(after.get(1)))
    assert_true(Bool(after.get(2)))
    assert_true(Bool(after.get(3)))
    before.close()
    after.close()
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
