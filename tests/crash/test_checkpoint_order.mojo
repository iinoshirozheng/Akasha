from akasha import PersistentCollection
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from std.testing import assert_equal, TestSuite


def test_manifest_publish_before_wal_rotation_recovers_once() raises:
    var directory = String("/tmp/akasha-phase5-crash-checkpoint")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/segment-1.bin")

    var collection = PersistentCollection.open(directory, 1)
    collection.upsert(42, [4.0])
    var pre_checkpoint_wal = read_file_bytes(directory + "/wal.bin")
    collection.flush()

    # Simulate power loss after manifest durability but before WAL replacement.
    write_file_sync(directory + "/wal.bin", pre_checkpoint_wal)
    collection.close()

    var recovered = PersistentCollection.open(directory, 1)
    var results = recovered.search_dot([1.0], 2)
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 42)
    assert_equal(recovered.last_sequence(), UInt64(1))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
