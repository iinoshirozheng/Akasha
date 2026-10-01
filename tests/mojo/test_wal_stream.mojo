from akasha.document import DocumentField, PayloadValue
from akasha.storage.checksum import BinaryWriter, crc32_range
from akasha.storage.filesystem import (
    append_file_sync,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.wal import (
    WalReader,
    WalRecord,
    decode_wal_bytes,
    encode_batch,
    encode_delete,
    encode_document_upsert,
    preflight_wal,
    repair_wal_tail,
    recover_wal,
)
from std.testing import assert_equal, assert_raises, TestSuite


def _mixed_wal() raises -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_bytes([UInt8(0x41), 0x4B, 0x57, 0x4C])
    writer.write_u16(1)
    writer.write_u8(1)
    writer.write_u8(0)
    writer.write_u32(40)
    writer.write_u64(1)
    writer.write_i64(-9)
    writer.write_u32(1)
    writer.write_f32(-3.0)
    var bytes = writer.take_bytes()
    var checksum = crc32_range(bytes, 4, len(bytes))
    writer.write_bytes(bytes)
    writer.write_u32(checksum)
    var fields: List[DocumentField] = [
        DocumentField("message", PayloadValue.string("借用" * 100)),
    ]
    var v2 = encode_document_upsert(2, 12, 1, [4.0], fields)
    writer.write_bytes(v2)
    var records = List[WalRecord]()
    records.append(WalRecord.delete(3, -9))
    records.append(WalRecord.upsert(4, 13, [5.0]))
    var v3 = encode_batch(1, records)
    writer.write_bytes(v3)
    return writer.take_bytes()


def _assert_records_equal(left: List[WalRecord], right: List[WalRecord]) raises:
    assert_equal(len(left), len(right))
    for i in range(len(left)):
        assert_equal(left[i].sequence, right[i].sequence)
        assert_equal(left[i].id, right[i].id)
        assert_equal(left[i].is_delete, right[i].is_delete)
        assert_equal(len(left[i].values), len(right[i].values))
        for j in range(len(left[i].values)):
            assert_equal(left[i].values[j], right[i].values[j])
        assert_equal(len(left[i].fields), len(right[i].fields))
        for j in range(len(left[i].fields)):
            assert_equal(left[i].fields[j].name, right[i].fields[j].name)
            assert_equal(
                left[i].fields[j].value.as_string(),
                right[i].fields[j].value.as_string(),
            )


def test_stream_returns_complete_envelopes_and_owns_returned_values() raises:
    var path = String("/tmp/akasha-wal-stream-owned.bin")
    var bytes = _mixed_wal()
    write_file_sync(path, bytes)
    var reader = WalReader(path, 1)
    assert_equal(reader.valid_length, 0)
    assert_equal(reader.source_length, len(bytes))
    var v1 = reader.read_next()
    assert_equal(len(v1), 1)
    assert_equal(v1[0].id, -9)
    assert_equal(reader.valid_length, 40)
    var v2 = reader.read_next()
    var v3 = reader.read_next()
    assert_equal(len(v3), 2)
    assert_equal(v3[0].is_delete, True)
    assert_equal(v3[1].values[0], Float32(5))
    assert_equal(reader.valid_length, len(bytes))
    assert_equal(len(reader.read_next()), 0)
    assert_equal(len(reader.read_next()), 0)
    assert_equal(v1[0].values[0], Float32(-3))
    assert_equal(v2[0].fields[0].value.as_string(), "借用" * 100)
    remove_file_if_exists(path)


def test_recovered_mutation_transfers_owned_buffers_without_copying() raises:
    var fields: List[DocumentField] = [
        DocumentField("body", PayloadValue.string("transfer" * 100)),
    ]
    var record = WalRecord.document_upsert(1, -9, [3.0], fields^)
    var vector_address = Int(record.values.unsafe_ptr())
    var fields_address = Int(record.fields.unsafe_ptr())
    var values = record.take_values()
    var payload = record.take_fields()
    assert_equal(Int(values.unsafe_ptr()), vector_address)
    assert_equal(Int(payload.unsafe_ptr()), fields_address)
    assert_equal(values[0], Float32(3))
    assert_equal(payload[0].value.as_string(), "transfer" * 100)


def test_stream_and_span_match_owned_decoder_at_every_torn_boundary() raises:
    var path = String("/tmp/akasha-wal-stream-cuts.bin")
    var bytes = _mixed_wal()
    var second_end = 40 + Int(
        UInt32(bytes[48])
        | UInt32(bytes[49]) << 8
        | UInt32(bytes[50]) << 16
        | UInt32(bytes[51]) << 24
    )
    for cut in range(len(bytes) + 1):
        var prefix = List[UInt8]()
        prefix.extend(Span(bytes)[:cut])
        # This fixture is not a durability test; avoid a sync for every cut.
        with open(path, "w") as file:
            file.write_all(Span(prefix))
        var expected = decode_wal_bytes(prefix.copy(), 1)
        var borrowed = decode_wal_bytes(Span(prefix), 1)
        var streamed = preflight_wal(path, 1)
        _assert_records_equal(expected, borrowed)
        _assert_records_equal(expected, streamed.records)
        var accepted = (
            len(bytes) if cut
            == len(bytes) else second_end if cut
            >= second_end else 40 if cut
            >= 40 else 0
        )
        var count = (
            4 if cut
            == len(bytes) else 2 if cut
            >= second_end else 1 if cut
            >= 40 else 0
        )
        assert_equal(len(expected), count)
        assert_equal(streamed.valid_length, accepted)
        assert_equal(streamed.source_length, cut)
    remove_file_if_exists(path)


def test_stream_rejects_file_shrinking_during_preflight() raises:
    var path = String("/tmp/akasha-wal-stream-shrink.bin")
    var bytes = _mixed_wal()
    write_file_sync(path, bytes)
    var reader = WalReader(path, 1)
    write_file_sync(path, [])
    with assert_raises():
        _ = reader.read_next()
    assert_equal(reader.valid_length, 0)
    remove_file_if_exists(path)


def test_failed_stream_cannot_resume_past_corrupt_envelope() raises:
    var path = String("/tmp/akasha-wal-stream-failed.bin")
    var bytes = _mixed_wal()
    bytes[36] ^= 1  # First v1 envelope CRC; the following v2/v3 remain valid.
    write_file_sync(path, bytes)
    var reader = WalReader(path, 1)
    with assert_raises():
        _ = reader.read_next()
    with assert_raises():
        _ = reader.read_next()
    assert_equal(reader.valid_length, 0)
    remove_file_if_exists(path)


def test_envelopes_cross_read_boundaries_and_grow_beyond_read_ahead() raises:
    var path = String("/tmp/akasha-wal-stream-boundaries.bin")
    var sizes: List[Int] = [0, 65000, 500, 131072, 0]
    with open(path, "w") as file:
        for i in range(len(sizes)):
            var fields: List[DocumentField] = [
                DocumentField("text", PayloadValue.string("x" * sizes[i])),
            ]
            var bytes = encode_document_upsert(
                UInt64(i + 1), i, 1, [Float32(i)], fields
            )
            file.write_all(Span(bytes))
    var reader = WalReader(path, 1)
    for i in range(len(sizes)):
        var records = reader.read_next()
        assert_equal(len(records), 1)
        assert_equal(records[0].id, i)
        assert_equal(records[0].values[0], Float32(i))
        assert_equal(records[0].fields[0].value.as_string(), "x" * sizes[i])
    assert_equal(len(reader.read_next()), 0)
    assert_equal(reader.valid_length, reader.source_length)
    remove_file_if_exists(path)


def test_preflight_defers_repair_and_truncate_preserves_prefix_and_append() raises:
    var path = String("/tmp/akasha-wal-stream-repair.bin")
    var bytes = _mixed_wal()
    write_file_sync(path, bytes)
    append_file_sync(path, [UInt8(0x41), 0x4B, 0x57])
    var state = preflight_wal(path, 1)
    assert_equal(state.needs_repair(), True)
    assert_equal(len(read_file_bytes(path)), len(bytes) + 3)
    repair_wal_tail(path, state)
    var repaired = read_file_bytes(path)
    assert_equal(len(repaired), len(bytes))
    for i in range(len(bytes)):
        assert_equal(repaired[i], bytes[i])
    var deleted = encode_delete(5, 13, 1)
    append_file_sync(path, deleted)
    var records = recover_wal(path, 1)
    assert_equal(len(records), 5)
    assert_equal(records[4].sequence, UInt64(5))
    remove_file_if_exists(path)


def test_repair_rejects_changed_length_or_missing_file_without_overwriting() raises:
    var path = String("/tmp/akasha-wal-stream-stale.bin")
    var bytes = _mixed_wal()
    write_file_sync(path, bytes)
    append_file_sync(path, [UInt8(1)])
    var state = preflight_wal(path, 1)
    append_file_sync(path, [UInt8(2)])
    with assert_raises():
        repair_wal_tail(path, state)
    assert_equal(len(read_file_bytes(path)), len(bytes) + 2)
    remove_file_if_exists(path)
    with assert_raises():
        repair_wal_tail(path, state)
    assert_equal(path_exists(path), False)


def test_stream_rejects_complete_corruption_and_invalid_header_lengths() raises:
    var path = String("/tmp/akasha-wal-stream-invalid.bin")
    var bytes = _mixed_wal()
    bytes[len(bytes) - 1] ^= 1
    write_file_sync(path, bytes)
    with assert_raises():
        _ = preflight_wal(path, 1)
    assert_equal(len(read_file_bytes(path)), len(bytes))
    for record_size in [0, 35, Int(UInt32.MAX)]:
        var header = List[UInt8]()
        header.extend(Span(bytes)[:32])
        for i in range(4):
            header[8 + i] = UInt8(UInt32(record_size) >> UInt32(8 * i))
        write_file_sync(path, header)
        with assert_raises():
            _ = preflight_wal(path, 1)
    remove_file_if_exists(path)


def test_stream_missing_and_empty_files_have_no_mutations_or_repair() raises:
    var path = String("/tmp/akasha-wal-stream-empty.bin")
    remove_file_if_exists(path)
    var missing = preflight_wal(path, 1)
    assert_equal(len(missing.records), 0)
    assert_equal(missing.needs_repair(), False)
    repair_wal_tail(path, missing)
    assert_equal(path_exists(path), False)
    write_file_sync(path, [])
    var empty = preflight_wal(path, 1)
    assert_equal(empty.valid_length, 0)
    assert_equal(empty.source_length, 0)
    with assert_raises():
        _ = preflight_wal(path, 0)
    remove_file_if_exists(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
