from akasha.storage.filesystem import (
    append_file_sync,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.wal import (
    append_wal,
    decode_wal_bytes,
    encode_delete,
    encode_upsert,
    replay_wal,
    WalRecord,
)
from std.testing import assert_equal, assert_raises, TestSuite


def test_wal_upsert_and_delete_round_trip() raises:
    var upsert_bytes = encode_upsert(1, 42, 2, [1.5, -2.0])
    var delete_bytes = encode_delete(2, 42, 2)
    var combined = List[UInt8]()
    for byte in upsert_bytes:
        combined.append(byte)
    for byte in delete_bytes:
        combined.append(byte)

    var records = decode_wal_bytes(combined^, 2)

    assert_equal(len(records), 2)
    assert_equal(records[0].sequence, UInt64(1))
    assert_equal(records[0].id, 42)
    assert_equal(records[0].is_delete, False)
    assert_equal(records[0].values[1], Float32(-2.0))
    assert_equal(records[1].sequence, UInt64(2))
    assert_equal(records[1].is_delete, True)
    assert_equal(len(records[1].values), 0)


def test_append_and_replay_fsync_wal() raises:
    var path = String("/tmp/akasha-phase3-wal-append.bin")
    remove_file_if_exists(path)
    var first = WalRecord.upsert(1, 10, [1.0, 0.0])
    var second = WalRecord.delete(2, 10)
    append_wal(path, 2, first)
    append_wal(path, 2, second)

    var records = replay_wal(path, 2)
    assert_equal(len(records), 2)
    assert_equal(records[1].is_delete, True)
    remove_file_if_exists(path)


def test_replay_ignores_incomplete_eof_record() raises:
    var path = String("/tmp/akasha-phase3-wal-tail.bin")
    remove_file_if_exists(path)
    var valid = encode_upsert(1, 7, 1, [3.0])
    write_file_sync(path, valid)
    var tail: List[UInt8] = [0x41, 0x4B, 0x57]
    append_file_sync(path, tail)

    var records = replay_wal(path, 1)

    assert_equal(len(records), 1)
    assert_equal(records[0].id, 7)
    remove_file_if_exists(path)


def test_complete_checksum_corruption_is_rejected() raises:
    var bytes = encode_upsert(1, 7, 1, [3.0])
    bytes[32] ^= 0x01

    with assert_raises():
        _ = decode_wal_bytes(bytes^, 1)


def test_dimension_mismatch_and_sequence_regression_are_rejected() raises:
    var wrong_dimension = encode_upsert(1, 7, 2, [1.0, 2.0])
    with assert_raises():
        _ = decode_wal_bytes(wrong_dimension^, 3)

    var newer = encode_delete(2, 7, 1)
    var older = encode_delete(1, 8, 1)
    var combined = List[UInt8]()
    for byte in newer:
        combined.append(byte)
    for byte in older:
        combined.append(byte)
    with assert_raises():
        _ = decode_wal_bytes(combined^, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
