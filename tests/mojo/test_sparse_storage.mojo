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
    latest_sparse_records,
    read_sparse_segment,
    read_sparse_snapshot,
    recover_sparse_wal,
    rotate_sparse_wal,
    SPARSE_SEGMENT_KIND_BASE,
    SPARSE_SEGMENT_KIND_DELTA,
    SparseWalRecord,
    write_sparse_segment,
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


def test_sparse_v2_base_and_delta_segments_round_trip() raises:
    var base_path = String("/tmp/akasha-phase10-sparse-base.bin")
    var delta_path = String("/tmp/akasha-phase10-sparse-delta.bin")
    remove_file_if_exists(base_path)
    remove_file_if_exists(delta_path)

    var base = List[SparseWalRecord]()
    var base_elements: List[SparseElement] = [SparseElement(1, 2.0)]
    base.append(SparseWalRecord.upsert(3, 7, base_elements^))
    var base_checksum = write_sparse_segment(
        base_path, SPARSE_SEGMENT_KIND_BASE, 0, 3, base
    )
    var restored_base = read_sparse_segment(base_path)

    assert_equal(restored_base.kind, SPARSE_SEGMENT_KIND_BASE)
    assert_equal(restored_base.min_sequence, UInt64(0))
    assert_equal(restored_base.last_sequence, UInt64(3))
    assert_equal(restored_base.checksum, base_checksum)
    assert_equal(restored_base.records[0].id, 7)
    assert_equal(restored_base.records[0].elements[0].term_id, 1)

    var delta = List[SparseWalRecord]()
    var delta_elements: List[SparseElement] = [SparseElement(9, 4.0)]
    delta.append(SparseWalRecord.upsert(4, 7, delta_elements^))
    delta.append(SparseWalRecord.delete(5, 8))
    _ = write_sparse_segment(delta_path, SPARSE_SEGMENT_KIND_DELTA, 4, 5, delta)
    var restored_delta = read_sparse_segment(delta_path)

    assert_equal(restored_delta.kind, SPARSE_SEGMENT_KIND_DELTA)
    assert_equal(len(restored_delta.records), 2)
    assert_equal(restored_delta.records[0].sequence, UInt64(4))
    assert_equal(restored_delta.records[1].is_delete, True)


def test_sparse_v2_canonicalizes_latest_record_and_rejects_base_delete() raises:
    var mutations = List[SparseWalRecord]()
    var first: List[SparseElement] = [SparseElement(1, 1.0)]
    var second: List[SparseElement] = [SparseElement(2, 2.0)]
    mutations.append(SparseWalRecord.upsert(1, 5, first^))
    mutations.append(SparseWalRecord.delete(2, 5))
    mutations.append(SparseWalRecord.upsert(3, 5, second^))
    var latest = latest_sparse_records(mutations)

    assert_equal(len(latest), 1)
    assert_equal(latest[0].sequence, UInt64(3))
    assert_equal(latest[0].is_delete, False)
    assert_equal(latest[0].elements[0].term_id, 2)

    var invalid = List[SparseWalRecord]()
    invalid.append(SparseWalRecord.delete(2, 5))
    with assert_raises():
        _ = write_sparse_segment(
            "/tmp/akasha-phase10-sparse-invalid.bin",
            SPARSE_SEGMENT_KIND_BASE,
            0,
            2,
            invalid,
        )


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
