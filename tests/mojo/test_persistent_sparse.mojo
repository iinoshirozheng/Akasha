from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    SparseElement,
)
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
)
from akasha.storage.manifest import load_manifest
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def _reset(directory: String) raises:
    ensure_directory(directory)
    for name in [
        "/wal.bin",
        "/wal.bin.tmp",
        "/sparse.wal",
        "/sparse.wal.tmp",
        "/manifest.bin",
        "/manifest.bin.tmp",
    ]:
        remove_file_if_exists(directory + name)
    for sequence in range(20):
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-delta-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-delta-" + String(sequence) + ".bin"
        )


def test_sparse_mutation_search_and_validation() raises:
    var path = String("/tmp/akasha-phase7-sparse-live")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.upsert(2, [2.0])
    collection.upsert_sparse(1, [SparseElement(1, 1.0)])
    collection.upsert_sparse(2, [SparseElement(1, 1.0), SparseElement(2, 3.0)])

    var results = collection.search_sparse_dot([SparseElement(2, 1.0)], 2)
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 2)
    var sequence = collection.last_sequence()
    with assert_raises():
        collection.upsert_sparse(99, [SparseElement(1, 1.0)])
    assert_equal(collection.last_sequence(), sequence)


def test_sparse_wal_and_checkpoint_recover_then_delete() raises:
    var path = String("/tmp/akasha-phase7-sparse-recovery")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(7, [1.0])
    collection.upsert_sparse(7, [SparseElement(9, 2.0)])
    collection.close()

    var wal_reopened = PersistentCollection.open(path, 1)
    assert_equal(
        wal_reopened.search_sparse_dot([SparseElement(9, 1.0)], 1)[0].id,
        7,
    )
    wal_reopened.flush()
    wal_reopened.close()

    var snapshot_reopened = PersistentCollection.open(path, 1)
    assert_equal(
        snapshot_reopened.search_sparse_dot([SparseElement(9, 1.0)], 1)[0].id,
        7,
    )
    snapshot_reopened.delete(7)
    assert_equal(
        len(snapshot_reopened.search_sparse_dot([SparseElement(9, 1.0)], 1)),
        0,
    )


def test_filtered_sparse_and_hybrid_search() raises:
    var path = String("/tmp/akasha-phase7-hybrid")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(1, 4):
        var fields = List[DocumentField]()
        fields.append(DocumentField("keep", PayloadValue.boolean(id != 3)))
        collection.upsert_document(id, [Float32(id)], fields^)
    collection.upsert_sparse(1, [SparseElement(1, 3.0)])
    collection.upsert_sparse(2, [SparseElement(1, 2.0)])
    collection.upsert_sparse(3, [SparseElement(1, 9.0)])
    var expression = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )

    var sparse = collection.search_sparse_dot_where(
        [SparseElement(1, 1.0)], 3, expression
    )
    var hybrid = collection.search_hybrid_dot_where(
        [1.0], [SparseElement(1, 1.0)], 2, 3, 60, expression
    )
    assert_equal(len(sparse), 2)
    assert_equal(sparse[0].id, 1)
    assert_equal(len(hybrid), 2)
    assert_equal(hybrid[0].id, 1)


def test_later_checkpoint_appends_sparse_delta_and_preserves_base() raises:
    var path = String("/tmp/akasha-phase7-sparse-cleanup")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.upsert_sparse(1, [SparseElement(1, 1.0)])
    collection.flush()
    assert_equal(path_exists(path + "/sparse-base-2.bin"), True)
    collection.upsert_sparse(1, [SparseElement(2, 1.0)])
    collection.flush()
    assert_equal(path_exists(path + "/sparse-base-2.bin"), True)
    assert_equal(path_exists(path + "/sparse-delta-3.bin"), True)
    var manifest = load_manifest(path, 1)
    assert_equal(len(manifest.segments), 2)
    assert_equal(manifest.segments[0].sparse_name, "sparse-base-2.bin")
    assert_equal(manifest.segments[1].sparse_name, "sparse-delta-3.bin")
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    var results = reopened.search_sparse_dot([SparseElement(2, 1.0)], 1)
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 1)


def test_full_compaction_rewrites_sparse_state_and_reclaims_inputs() raises:
    var path = String("/tmp/akasha-phase10-sparse-compaction")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.upsert_sparse(1, [SparseElement(1, 1.0)])
    collection.flush()
    collection.upsert_sparse(1, [SparseElement(2, 2.0)])
    collection.flush()

    collection.compact()

    assert_equal(path_exists(path + "/sparse-base-2.bin"), False)
    assert_equal(path_exists(path + "/sparse-delta-3.bin"), False)
    var manifest = load_manifest(path, 1)
    assert_equal(len(manifest.segments), 1)
    assert_true(manifest.segments[0].sparse_name.startswith("sparse-compact-"))
    assert_true(path_exists(path + "/" + manifest.segments[0].sparse_name))
    collection.close()
    var reopened = PersistentCollection.open(path, 1)
    var results = reopened.search_sparse_dot([SparseElement(2, 1.0)], 1)
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 1)


def test_reinsert_does_not_inherit_sparse_after_reopen() raises:
    # A delete removes the whole point; a later reinsert starts without the
    # old sparse field, both from the WAL tail and across a checkpoint.
    for checkpoint in range(2):
        var path = String("/tmp/akasha-phase7-sparse-reinsert-") + String(
            checkpoint
        )
        _reset(path)
        var collection = PersistentCollection.open(path, 1)
        collection.upsert(1, [1.0])
        collection.upsert_sparse(1, [SparseElement(1, 1.0)])
        if checkpoint == 1:
            collection.flush()
        collection.delete(1)
        collection.upsert(1, [2.0])
        assert_equal(
            len(collection.search_sparse_dot([SparseElement(1, 1.0)], 1)), 0
        )
        collection.close()
        var reopened = PersistentCollection.open(path, 1)
        assert_equal(
            len(reopened.search_sparse_dot([SparseElement(1, 1.0)], 1)), 0
        )
        reopened.flush()
        reopened.close()
        var again = PersistentCollection.open(path, 1)
        assert_equal(
            len(again.search_sparse_dot([SparseElement(1, 1.0)], 1)), 0
        )


def test_sparse_existence_errors_preserve_validation_order_and_wal() raises:
    var path = String("/tmp/akasha-readonly-sparse-errors")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(-7, [1.0, 2.0])
    collection.upsert(-13, [3.0, 4.0])
    collection.upsert_sparse(-7, [SparseElement(9, 1.0)])
    collection.delete(-13)
    var sequence = collection.last_sequence()
    var before = read_file_bytes(path + "/sparse.wal")
    for id in [-13, -99, Int.MIN]:
        var message = String()
        try:
            collection.upsert_sparse(id, [SparseElement(-1, 1.0)])
        except error:
            message = String(error)
        assert_equal(message, "sparse term IDs must be non-negative")
        message = ""
        try:
            collection.upsert_sparse(id, [SparseElement(9, 1.0)])
        except error:
            message = String(error)
        assert_equal(message, "sparse vectors require an existing live point")
        assert_equal(collection.last_sequence(), sequence)
    var after = read_file_bytes(path + "/sparse.wal")
    assert_equal(len(after), len(before))
    for i in range(len(before)):
        assert_equal(after[i], before[i])
    collection.upsert_sparse(-7, [SparseElement(9, 2.0)])
    assert_equal(collection.last_sequence(), sequence + 1)
    assert_equal(
        collection.search_sparse_dot([SparseElement(9, 1.0)], 1)[0].id, -7
    )
    collection.close()


def test_sparse_failed_append_preserves_large_document_and_sequence() raises:
    var path = String("/tmp/akasha-readonly-sparse-append")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var fields: List[DocumentField] = [
        DocumentField("body", PayloadValue.string("x" * 65536))
    ]
    collection.upsert_document(-7, [1.0, 2.0], fields^)
    collection.upsert_sparse(-7, [SparseElement(9, 1.0)])
    var sequence = collection.last_sequence()
    var before = read_file_bytes(path + "/sparse.wal")
    # The file API creates missing parent directories. An existing regular
    # file cannot become a parent, so this fails without touching the real WAL.
    var original = collection._sparse_wal_path.copy()
    collection._sparse_wal_path = path + "/sparse.wal/child"
    with assert_raises():
        collection.upsert_sparse(-7, [SparseElement(10, 2.0)])
    collection._sparse_wal_path = original^
    assert_equal(collection.last_sequence(), sequence)
    assert_equal(
        collection.search_sparse_dot([SparseElement(9, 1.0)], 1)[0].score,
        Float32(1),
    )
    assert_equal(
        len(collection.search_sparse_dot([SparseElement(10, 1.0)], 1)), 0
    )
    var after = read_file_bytes(path + "/sparse.wal")
    assert_equal(len(after), len(before))
    for i in range(len(before)):
        assert_equal(after[i], before[i])
    collection.upsert_sparse(-7, [SparseElement(10, 2.0)])
    assert_equal(collection.last_sequence(), sequence + 1)
    collection.close()
    var reopened = PersistentCollection.open(path, 2)
    var document = reopened.get(-7)
    assert_equal(document.value().vector[1], Float32(2))
    assert_equal(
        document.value().get_field("body").value().as_string(), "x" * 65536
    )
    assert_equal(
        reopened.search_sparse_dot([SparseElement(10, 1.0)], 1)[0].score,
        Float32(2),
    )
    reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
