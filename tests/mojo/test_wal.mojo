from akasha.document import DocumentField, PayloadValue
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import (
    append_file_sync,
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.wal import (
    append_wal,
    append_wal_batch,
    decode_wal_bytes,
    encode_batch,
    encode_delete,
    encode_document_upsert,
    encode_upsert,
    replay_wal,
    recover_wal,
    rotate_wal,
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


def test_wal_v2_round_trips_document_and_vector_only_payloads() raises:
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("hello")))
    fields.append(DocumentField("page", PayloadValue.integer(3)))
    var document = encode_document_upsert(1, 42, 2, [1.0, 2.0], fields)
    var vector_only = encode_upsert(2, 7, 2, [3.0, 4.0])
    var deleted = encode_delete(3, 42, 2)
    var combined = List[UInt8]()
    for byte in document:
        combined.append(byte)
    for byte in vector_only:
        combined.append(byte)
    for byte in deleted:
        combined.append(byte)

    var records = decode_wal_bytes(combined^, 2)

    assert_equal(len(records), 3)
    assert_equal(records[0].fields[0].value.as_string(), "hello")
    assert_equal(records[0].fields[1].value.as_int(), Int64(3))
    assert_equal(len(records[1].fields), 0)
    assert_equal(len(records[2].fields), 0)


def test_wal_v2_rejects_malformed_payload_with_valid_record_crc() raises:
    var fields = List[DocumentField]()
    fields.append(DocumentField("x", PayloadValue.boolean(True)))
    var bytes = encode_document_upsert(1, 1, 1, [1.0], fields)
    bytes[48] = 2  # Invalid Bool body inside the length-prefixed payload.
    var checksum = crc32_range(bytes, 4, len(bytes) - 4)
    for byte_index in range(4):
        bytes[len(bytes) - 4 + byte_index] = UInt8(
            checksum >> UInt32(byte_index * 8)
        )

    with assert_raises():
        _ = decode_wal_bytes(bytes^, 1)


def test_rotate_wal_atomically_publishes_empty_file() raises:
    var directory = String("/tmp/akasha-phase5-wal-rotation")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    var record = WalRecord.upsert(1, 10, [1.0])
    append_wal(directory + "/wal.bin", 1, record)

    rotate_wal(directory)

    assert_equal(len(read_file_bytes(directory + "/wal.bin")), 0)
    assert_equal(path_exists(directory + "/wal.bin.tmp"), False)


def test_wal_v3_batch_round_trips_mixed_atomic_mutations() raises:
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("batched")))
    var records = List[WalRecord]()
    records.append(WalRecord.upsert(10, 1, [1.0, 0.0]))
    records.append(WalRecord.delete(11, 2))
    records.append(WalRecord.document_upsert(12, 3, [0.0, 1.0], fields^))

    var bytes = encode_batch(2, records)
    var decoded = decode_wal_bytes(bytes^, 2)

    assert_equal(len(decoded), 3)
    assert_equal(decoded[0].sequence, UInt64(10))
    assert_equal(decoded[1].sequence, UInt64(11))
    assert_equal(decoded[1].is_delete, True)
    assert_equal(decoded[2].sequence, UInt64(12))
    assert_equal(decoded[2].fields[0].value.as_string(), "batched")


def test_wal_v3_batch_rejects_empty_and_noncontiguous_sequences() raises:
    var empty = List[WalRecord]()
    with assert_raises():
        _ = encode_batch(1, empty)

    var records = List[WalRecord]()
    records.append(WalRecord.upsert(1, 1, [1.0]))
    records.append(WalRecord.delete(3, 1))
    with assert_raises():
        _ = encode_batch(1, records)

    var overflowing = List[WalRecord]()
    overflowing.append(WalRecord.upsert(UInt64.MAX, 1, [1.0]))
    overflowing.append(WalRecord.delete(0, 1))
    with assert_raises():
        _ = encode_batch(1, overflowing)


def test_wal_v2_and_v3_share_strict_sequence_ordering() raises:
    var single = encode_upsert(1, 1, 1, [1.0])
    var records = List[WalRecord]()
    records.append(WalRecord.upsert(2, 2, [2.0]))
    records.append(WalRecord.delete(3, 1))
    var batch = encode_batch(1, records)
    var combined = List[UInt8]()
    for byte in single:
        combined.append(byte)
    for byte in batch:
        combined.append(byte)

    var decoded = decode_wal_bytes(combined^, 1)
    assert_equal(len(decoded), 3)
    assert_equal(decoded[2].sequence, UInt64(3))

    var regressing = List[WalRecord]()
    regressing.append(WalRecord.upsert(1, 2, [2.0]))
    var old_batch = encode_batch(1, regressing)
    var invalid = List[UInt8]()
    var fresh_single = encode_upsert(1, 1, 1, [1.0])
    for byte in fresh_single:
        invalid.append(byte)
    for byte in old_batch:
        invalid.append(byte)
    with assert_raises():
        _ = decode_wal_bytes(invalid^, 1)


def test_torn_wal_v3_batch_recovers_none_of_its_mutations() raises:
    var path = String("/tmp/akasha-phase11-wal-batch-tail.bin")
    remove_file_if_exists(path)
    var first = WalRecord.upsert(1, 1, [1.0])
    append_wal(path, 1, first)
    var prefix_length = len(read_file_bytes(path))

    var records = List[WalRecord]()
    records.append(WalRecord.upsert(2, 2, [2.0]))
    records.append(WalRecord.delete(3, 1))
    var batch = encode_batch(1, records)
    for _ in range(7):
        _ = batch.pop()
    append_file_sync(path, batch)

    var recovered = recover_wal(path, 1)

    assert_equal(len(recovered), 1)
    assert_equal(recovered[0].id, 1)
    assert_equal(len(read_file_bytes(path)), prefix_length)
    remove_file_if_exists(path)


def test_complete_wal_v3_batch_corruption_is_rejected() raises:
    var records = List[WalRecord]()
    records.append(WalRecord.upsert(1, 1, [1.0]))
    records.append(WalRecord.delete(2, 1))
    var batch = encode_batch(1, records)
    batch[40] ^= 0x01
    with assert_raises():
        _ = decode_wal_bytes(batch^, 1)


def test_append_wal_v3_batch_fsyncs_one_envelope() raises:
    var path = String("/tmp/akasha-phase11-wal-batch-append.bin")
    remove_file_if_exists(path)
    var records = List[WalRecord]()
    records.append(WalRecord.upsert(1, 1, [1.0]))
    records.append(WalRecord.upsert(2, 2, [2.0]))

    append_wal_batch(path, 1, records)
    var recovered = replay_wal(path, 1)

    assert_equal(len(recovered), 2)
    assert_equal(recovered[1].id, 2)
    remove_file_if_exists(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
