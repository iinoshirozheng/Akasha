from akasha.index.sparse import SparseElement, SparseRecord
from akasha.storage.filesystem import (
    append_file_sync,
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
)
from akasha.storage.sparse_store import (
    append_sparse_wal,
    read_sparse_snapshot,
    recover_sparse_wal,
    rotate_sparse_wal,
    SparseWalRecord,
    write_sparse_snapshot,
)
from std.testing import assert_equal, assert_raises, TestSuite


def test_sparse_snapshot_round_trip_and_sequence_validation() raises:
    var path = String("/tmp/akasha-phase7-sparse.snapshot")
    remove_file_if_exists(path)
    var records = List[SparseRecord]()
    var first: List[SparseElement] = [
        SparseElement(1, 1.0),
        SparseElement(8, 2.0),
    ]
    records.append(SparseRecord(42, first^))
    _ = write_sparse_snapshot(path, 7, records)

    var restored = read_sparse_snapshot(path, 7)
    assert_equal(len(restored), 1)
    assert_equal(restored[0].id, 42)
    assert_equal(restored[0].elements[1].term_id, 8)
    with assert_raises():
        _ = read_sparse_snapshot(path, 8)


def test_sparse_wal_recovers_upsert_delete_and_torn_tail() raises:
    var path = String("/tmp/akasha-phase7-sparse.wal")
    remove_file_if_exists(path)
    var elements: List[SparseElement] = [SparseElement(3, 2.0)]
    append_sparse_wal(path, SparseWalRecord.upsert(1, 7, elements^))
    append_sparse_wal(path, SparseWalRecord.delete(2, 7))
    var tail: List[UInt8] = [0x41, 0x4B, 0x53]
    append_file_sync(path, tail)

    var records = recover_sparse_wal(path)
    assert_equal(len(records), 2)
    assert_equal(records[0].elements[0].term_id, 3)
    assert_equal(records[1].is_delete, True)
    assert_equal(len(read_file_bytes(path)) > 3, True)


def test_sparse_wal_rotation_publishes_empty_file() raises:
    var directory = String("/tmp/akasha-phase7-sparse-rotate")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/sparse.wal")
    remove_file_if_exists(directory + "/sparse.wal.tmp")
    var elements: List[SparseElement] = [SparseElement(1, 1.0)]
    append_sparse_wal(
        directory + "/sparse.wal",
        SparseWalRecord.upsert(1, 1, elements^),
    )

    rotate_sparse_wal(directory)
    assert_equal(len(read_file_bytes(directory + "/sparse.wal")), 0)
    assert_equal(path_exists(directory + "/sparse.wal.tmp"), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
