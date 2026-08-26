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
    remove_file_if_exists,
)
from akasha.storage.manifest import load_manifest
from std.testing import assert_equal, assert_raises, TestSuite


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
