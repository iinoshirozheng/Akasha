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
from akasha.index.sparse import SparseElement
from std.python import Python


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


def test_failed_batch_wal_requires_reopen_and_never_publishes_staged_rows() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(prefix="akasha-batch-io-")
    )
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(7, [1, 2])
    var old = collection.snapshot()
    # Mojo open creates missing parent directories; an existing directory is
    # an actual append failure rather than a path that can be created.
    collection._wal_path = path
    var mutations: List[BatchMutation] = [
        BatchMutation.upsert(7, [3, 4]),
        BatchMutation.upsert(8, [5, 6]),
    ]
    with assert_raises():
        _ = collection.apply_batch(mutations)
    with assert_raises(contains="requires reopen"):
        _ = collection.snapshot()
    with assert_raises(contains="requires reopen"):
        collection.upsert(9, [7, 8])
    assert_equal(old.get(7).value().vector[0], Float32(1))
    assert_false(Bool(old.get(8)))
    old.close()
    collection.close()
    var recovered = PersistentCollection.open(path, 2)
    assert_equal(recovered.get(7).value().vector[0], Float32(1))
    assert_false(Bool(recovered.get(8)))
    recovered.close()
    Python.import_module("shutil").rmtree(path)


def test_batch_stages_only_changed_ids_preserving_ordinals_and_sparse_delete_reinsert() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-batch-staging-"
        )
    )
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(7, [1, 2])
    collection.upsert(10, [2, 3])
    collection.upsert_sparse(7, [SparseElement(1, 5)])
    collection.upsert_sparse(10, [SparseElement(1, 6)])
    var old = collection.snapshot()
    var first_address = collection._memtable.entry_ref_at(0).dense_address()
    var unchanged_address = collection._memtable.entry_ref_at(1).dense_address()
    var mutations: List[BatchMutation] = [
        BatchMutation.upsert(-4, [5, 6]),
        BatchMutation.delete(7),
        BatchMutation.upsert(7, [3, 4]),
        BatchMutation.upsert(-4, [7, 8]),
        BatchMutation.delete(-9),
    ]
    _ = collection.apply_batch(mutations)
    assert_equal(collection._memtable.ordinal_for(7), 0)
    assert_equal(collection._memtable.ordinal_for(10), 1)
    assert_equal(collection._memtable.ordinal_for(-4), 2)
    assert_equal(collection._memtable.ordinal_for(-9), 3)
    assert_equal(
        collection._memtable.entry_ref_at(1).dense_address(), unchanged_address
    )
    assert_true(
        collection._memtable.entry_ref_at(0).dense_address() != first_address
    )
    assert_false(collection._memtable.entry_ref_at(0).has_sparse())
    assert_true(collection._memtable.entry_ref_at(1).has_sparse())
    assert_equal(collection.get(-4).value().vector[0], Float32(7))
    assert_equal(old.get(7).value().vector[0], Float32(1))
    old.close()
    collection.close()
    var recovered = PersistentCollection.open(path, 2)
    assert_false(
        recovered._memtable.entry_ref_at(
            recovered._memtable.ordinal_for(7)
        ).has_sparse()
    )
    assert_true(
        recovered._memtable.entry_ref_at(
            recovered._memtable.ordinal_for(10)
        ).has_sparse()
    )
    assert_equal(recovered.get(-4).value().vector[0], Float32(7))
    recovered.close()
    Python.import_module("shutil").rmtree(path)


def test_committed_batch_publication_failure_requires_complete_recovery() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-batch-publish-"
        )
    )
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(7, [1, 2])
    collection.upsert(8, [2, 3])
    var old = collection.snapshot()
    # Inject a derived-index failure after ID 8 has been deleted and after the
    # whole envelope is durable. Bulk insertion rejects an existing live ID.
    collection._metadata._bulk_loading = True
    var mutations: List[BatchMutation] = [
        BatchMutation.delete(8),
        BatchMutation.upsert(7, [3, 4]),
    ]
    with assert_raises(contains="unique point IDs"):
        _ = collection.apply_batch(mutations)
    with assert_raises(contains="requires reopen"):
        _ = collection.snapshot()
    with assert_raises(contains="requires reopen"):
        _ = collection.get(8)
    assert_true(Bool(old.get(8)))
    assert_equal(old.get(7).value().vector[0], Float32(1))
    old.close()
    collection.close()
    var recovered = PersistentCollection.open(path, 2)
    assert_equal(recovered.last_sequence(), UInt64(4))
    assert_false(Bool(recovered.get(8)))
    assert_equal(recovered.get(7).value().vector[0], Float32(3))
    recovered.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
