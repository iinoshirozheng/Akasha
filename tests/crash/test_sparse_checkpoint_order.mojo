from akasha import PersistentCollection, SparseElement
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from std.testing import assert_equal, TestSuite


def test_sparse_manifest_commit_before_wal_rotation_recovers_once() raises:
    var directory = String("/tmp/akasha-phase7-crash-sparse-checkpoint")
    ensure_directory(directory)
    for name in [
        "/wal.bin",
        "/sparse.wal",
        "/manifest.bin",
        "/segment-2.bin",
        "/sparse-2.bin",
    ]:
        remove_file_if_exists(directory + name)
    var collection = PersistentCollection.open(directory, 1)
    collection.upsert(42, [1.0])
    collection.upsert_sparse(42, [SparseElement(7, 3.0)])
    var old_sparse_wal = read_file_bytes(directory + "/sparse.wal")
    collection.flush()

    write_file_sync(directory + "/sparse.wal", old_sparse_wal)
    collection.close()
    var recovered = PersistentCollection.open(directory, 1)
    var results = recovered.search_sparse_dot([SparseElement(7, 1.0)], 2)
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 42)
    assert_equal(recovered.last_sequence(), UInt64(2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
