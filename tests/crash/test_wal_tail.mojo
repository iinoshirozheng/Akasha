from akasha import PersistentCollection
from akasha.storage.filesystem import (
    append_file_sync,
    ensure_directory,
    remove_file_if_exists,
)
from akasha.storage.wal import encode_upsert
from std.testing import assert_equal, TestSuite


def test_reopen_repairs_torn_tail_before_next_append() raises:
    var directory = String("/tmp/akasha-phase3-crash-tail")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/manifest.bin")

    var collection = PersistentCollection.open(directory, 1)
    collection.upsert(1, [1.0])

    var next_record = encode_upsert(2, 2, 1, [2.0])
    var torn = List[UInt8](capacity=34)
    for index in range(34):
        torn.append(next_record[index])
    append_file_sync(directory + "/wal.bin", torn)
    collection.close()

    var recovered = PersistentCollection.open(directory, 1)
    var query: List[Float32] = [1.0]
    assert_equal(len(recovered.search_dot(query, 2)), 1)
    recovered.upsert(2, [2.0])
    recovered.close()

    var reopened = PersistentCollection.open(directory, 1)
    var results = reopened.search_dot(query, 2)
    assert_equal(len(results), 2)
    assert_equal(results[0].id, 2)
    assert_equal(results[1].id, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
