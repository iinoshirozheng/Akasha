from akasha import PersistentCollection
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
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
    for sequence in range(11):
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin.tmp"
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
