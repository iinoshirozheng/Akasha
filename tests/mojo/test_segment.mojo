from akasha.document import DocumentField, PayloadValue
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import remove_file_if_exists
from akasha.storage.memtable import MemTable, MemTableEntry
from akasha.storage.segment import (
    decode_segment_bytes,
    encode_segment,
    encode_segment_v3,
    read_segment,
    SEGMENT_KIND_BASE,
    SEGMENT_KIND_DELTA,
    write_segment,
    write_segment_v3,
)
from std.testing import assert_equal, assert_raises, TestSuite


def _snapshot_bytes() raises -> List[UInt8]:
    var table = MemTable(2)
    table.apply_upsert(20, 1, [1.0, 0.0])
    table.apply_upsert(10, 2, [0.0, 1.0])
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("twenty")))
    table.apply_document_upsert(20, 3, [2.0, 0.0], fields^)
    var entries = table.live_entries()
    return encode_segment(2, table.last_sequence, entries)


def test_segment_round_trip_preserves_sorted_live_snapshot() raises:
    var bytes = _snapshot_bytes()
    var snapshot = decode_segment_bytes(bytes^, 2)

    assert_equal(snapshot.dimension, 2)
    assert_equal(snapshot.format_version, 2)
    assert_equal(snapshot.kind, SEGMENT_KIND_BASE)
    assert_equal(snapshot.min_sequence, UInt64(0))
    assert_equal(snapshot.last_sequence, UInt64(3))
    assert_equal(len(snapshot.entries), 2)
    assert_equal(snapshot.entries[0].id, 10)
    assert_equal(snapshot.entries[1].id, 20)
    assert_equal(snapshot.entries[1].sequence, UInt64(3))
    assert_equal(snapshot.entries[1].values[0], Float32(2.0))
    assert_equal(snapshot.entries[1].fields[0].value.as_string(), "twenty")
    assert_equal(len(snapshot.entries[0].fields), 0)


def test_segment_file_round_trip() raises:
    var path = String("/tmp/akasha-phase3-segment.bin")
    remove_file_if_exists(path)
    var table = MemTable(1)
    table.apply_upsert(7, 4, [3.0])
    var entries = table.live_entries()

    _ = write_segment(path, 1, table.last_sequence, entries)
    var snapshot = read_segment(path, 1)

    assert_equal(snapshot.last_sequence, UInt64(4))
    assert_equal(snapshot.entries[0].id, 7)
    remove_file_if_exists(path)


def test_segment_v3_base_round_trip_preserves_live_records() raises:
    var table = MemTable(2)
    table.apply_upsert(5, 1, [1.0, 2.0])
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("base")))
    table.apply_document_upsert(9, 3, [3.0, 4.0], fields^)
    var entries = table.live_entries()
    var bytes = encode_segment_v3(2, SEGMENT_KIND_BASE, 0, 3, entries)
    var snapshot = decode_segment_bytes(bytes^, 2)

    assert_equal(snapshot.format_version, 3)
    assert_equal(snapshot.kind, SEGMENT_KIND_BASE)
    assert_equal(snapshot.min_sequence, UInt64(0))
    assert_equal(snapshot.last_sequence, UInt64(3))
    assert_equal(len(snapshot.entries), 2)
    assert_equal(snapshot.entries[1].id, 9)
    assert_equal(snapshot.entries[1].fields[0].value.as_string(), "base")


def test_segment_v3_delta_round_trips_upsert_and_tombstone() raises:
    var entries = List[MemTableEntry]()
    var fields = List[DocumentField]()
    fields.append(DocumentField("kind", PayloadValue.string("delta")))
    entries.append(MemTableEntry.with_fields(10, 4, False, [4.0], fields^))
    entries.append(MemTableEntry(20, 5, True, List[Float32]()))
    var path = String("/tmp/akasha-phase10-delta-segment.bin")
    remove_file_if_exists(path)

    _ = write_segment_v3(path, 1, SEGMENT_KIND_DELTA, 4, 5, entries)
    var snapshot = read_segment(path, 1)

    assert_equal(snapshot.format_version, 3)
    assert_equal(snapshot.kind, SEGMENT_KIND_DELTA)
    assert_equal(snapshot.min_sequence, UInt64(4))
    assert_equal(snapshot.last_sequence, UInt64(5))
    assert_equal(len(snapshot.entries), 2)
    assert_equal(snapshot.entries[0].tombstone, False)
    assert_equal(snapshot.entries[0].fields[0].value.as_string(), "delta")
    assert_equal(snapshot.entries[1].id, 20)
    assert_equal(snapshot.entries[1].tombstone, True)
    assert_equal(len(snapshot.entries[1].values), 0)
    remove_file_if_exists(path)


def test_segment_v3_rejects_invalid_kind_ranges_and_base_tombstones() raises:
    var tombstones = List[MemTableEntry]()
    tombstones.append(MemTableEntry(1, 2, True, List[Float32]()))
    with assert_raises():
        _ = encode_segment_v3(1, SEGMENT_KIND_BASE, 0, 2, tombstones)

    var live = List[MemTableEntry]()
    live.append(MemTableEntry(1, 2, False, [1.0]))
    with assert_raises():
        _ = encode_segment_v3(1, 99, 1, 2, live)
    with assert_raises():
        _ = encode_segment_v3(1, SEGMENT_KIND_DELTA, 3, 2, live)
    with assert_raises():
        _ = encode_segment_v3(1, SEGMENT_KIND_DELTA, 3, 4, live)


def test_segment_rejects_truncation_and_checksum_corruption() raises:
    var truncated = _snapshot_bytes()
    _ = truncated.pop()
    with assert_raises():
        _ = decode_segment_bytes(truncated^, 2)

    var corrupt = _snapshot_bytes()
    corrupt[28] ^= 0x01
    with assert_raises():
        _ = decode_segment_bytes(corrupt^, 2)


def test_segment_rejects_dimension_mismatch() raises:
    var bytes = _snapshot_bytes()
    with assert_raises():
        _ = decode_segment_bytes(bytes^, 3)


def test_segment_v2_rejects_invalid_payload_length_and_body() raises:
    var table = MemTable(1)
    var fields = List[DocumentField]()
    fields.append(DocumentField("x", PayloadValue.boolean(True)))
    table.apply_document_upsert(1, 1, [1.0], fields^)
    var entries = table.live_entries()
    var invalid_length = encode_segment(1, 1, entries)
    invalid_length[48] = 0xFF
    var checksum = crc32_range(invalid_length, 4, len(invalid_length) - 4)
    for byte_index in range(4):
        invalid_length[len(invalid_length) - 4 + byte_index] = UInt8(
            checksum >> UInt32(byte_index * 8)
        )
    with assert_raises():
        _ = decode_segment_bytes(invalid_length^, 1)

    var fresh_entries = table.live_entries()
    var invalid_bool = encode_segment(1, 1, fresh_entries)
    invalid_bool[60] = 2
    checksum = crc32_range(invalid_bool, 4, len(invalid_bool) - 4)
    for byte_index in range(4):
        invalid_bool[len(invalid_bool) - 4 + byte_index] = UInt8(
            checksum >> UInt32(byte_index * 8)
        )
    with assert_raises():
        _ = decode_segment_bytes(invalid_bool^, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
