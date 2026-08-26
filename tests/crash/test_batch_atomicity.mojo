from akasha import PersistentCollection
from akasha.storage.filesystem import (
    append_file_sync,
    ensure_directory,
    read_file_bytes,
    remove_file_if_exists,
)
from akasha.storage.wal import encode_batch, WalRecord
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def test_torn_batch_is_repaired_without_exposing_a_prefix() raises:
    var path = String("/tmp/akasha-phase11-crash-batch")
    ensure_directory(path)
    remove_file_if_exists(path + "/manifest.bin")
    remove_file_if_exists(path + "/manifest.bin.tmp")
    remove_file_if_exists(path + "/wal.bin")
    remove_file_if_exists(path + "/wal.bin.tmp")
    remove_file_if_exists(path + "/sparse.wal")
    remove_file_if_exists(path + "/sparse.wal.tmp")
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.close()
    var valid_size = len(read_file_bytes(path + "/wal.bin"))

    var records = List[WalRecord]()
    records.append(WalRecord.upsert(2, 2, [2.0]))
    records.append(WalRecord.delete(3, 1))
    records.append(WalRecord.upsert(4, 3, [3.0]))
    var torn = encode_batch(1, records)
    for _ in range(9):
        _ = torn.pop()
    append_file_sync(path + "/wal.bin", torn)

    var recovered = PersistentCollection.open(path, 1)
    assert_equal(recovered.last_sequence(), UInt64(1))
    assert_true(Bool(recovered.get(1)))
    assert_false(Bool(recovered.get(2)))
    assert_false(Bool(recovered.get(3)))
    assert_equal(len(read_file_bytes(path + "/wal.bin")), valid_size)
    recovered.upsert(4, [4.0])
    assert_equal(recovered.last_sequence(), UInt64(2))
    recovered.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
