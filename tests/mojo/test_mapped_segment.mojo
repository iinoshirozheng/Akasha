from akasha.document import DocumentField, PayloadValue
from akasha.document.codec import encode_payload
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import write_file_sync, remove_file_if_exists
from akasha.storage.memtable import MemTableEntry
from akasha.storage.segment import (
    decode_segment_bytes,
    encode_segment,
    encode_segment_v3,
    read_segment,
    SEGMENT_KIND_BASE,
    SEGMENT_KIND_DELTA,
)
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite
from test_segment_v1_compat import _encode_v1_segment


def _same(bytes: List[UInt8], dimension: Int) raises:
    var path = String("/tmp/akasha-mapped-segment-equivalence.bin")
    write_file_sync(path, bytes)
    var mapped = read_segment(path, dimension)
    var owned = decode_segment_bytes(bytes.copy(), dimension)
    # The returned records are independent of the source file and mapping.
    write_file_sync(path, [UInt8(0)])
    remove_file_if_exists(path)
    assert_equal(mapped.dimension, owned.dimension)
    assert_equal(mapped.format_version, owned.format_version)
    assert_equal(mapped.kind, owned.kind)
    assert_equal(mapped.min_sequence, owned.min_sequence)
    assert_equal(mapped.last_sequence, owned.last_sequence)
    assert_equal(mapped.checksum, owned.checksum)
    assert_equal(len(mapped.entries), len(owned.entries))
    for index in range(len(owned.entries)):
        ref lhs = mapped.entries[index]
        ref rhs = owned.entries[index]
        assert_equal(lhs.id, rhs.id)
        assert_equal(lhs.sequence, rhs.sequence)
        assert_equal(lhs.tombstone, rhs.tombstone)
        assert_equal(len(lhs.values()), len(rhs.values()))
        for component in range(len(rhs.values())):
            assert_equal(
                bitcast[DType.uint32](lhs.values()[component]),
                bitcast[DType.uint32](rhs.values()[component]),
            )
        var left_payload = encode_payload(lhs.fields())
        var right_payload = encode_payload(rhs.fields())
        assert_equal(len(left_payload), len(right_payload))
        for byte in range(len(left_payload)):
            assert_equal(left_payload[byte], right_payload[byte])


def _entries() raises -> List[MemTableEntry]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("文字", PayloadValue.string("原始資料")))
    var values: List[Float32] = [
        bitcast[DType.float32](UInt32(0x80000000)),
        bitcast[DType.float32](UInt32(0x7FC01234)),
    ]
    var entries = List[MemTableEntry]()
    entries.append(MemTableEntry.with_fields(-3, 1, False, values^, fields^))
    return entries^


def test_mapped_segments_match_owned_legacy_versions_and_raw_bits() raises:
    _same(_encode_v1_segment(), 2)
    var entries = _entries()
    _same(encode_segment(2, 1, entries), 2)
    _same(encode_segment_v3(2, SEGMENT_KIND_BASE, 0, 1, entries), 2)
    entries.append(MemTableEntry(9, 2, True, []))
    _same(encode_segment_v3(2, SEGMENT_KIND_DELTA, 1, 2, entries), 2)


def _reject(bytes: List[UInt8], dimension: Int) raises:
    var path = String("/tmp/akasha-mapped-segment-invalid.bin")
    write_file_sync(path, bytes)
    with assert_raises():
        _ = read_segment(path, dimension)
    with assert_raises():
        _ = decode_segment_bytes(bytes.copy(), dimension)
    remove_file_if_exists(path)


def test_mapped_segments_reject_every_torn_prefix_and_corruption() raises:
    var entries = _entries()
    var bytes = encode_segment_v3(2, SEGMENT_KIND_BASE, 0, 1, entries)
    var prefix = List[UInt8]()
    for end in range(len(bytes)):
        _reject(prefix, 2)
        prefix.append(bytes[end])
    bytes[45] ^= 1
    _reject(bytes, 2)


def test_mapped_segments_reject_checksummed_invalid_headers_and_wrong_dimension() raises:
    var entries = _entries()
    var fresh = encode_segment(2, 1, entries)
    _reject(fresh, 3)
    for offset in [0, 4, 6, 19]:
        var bytes = fresh.copy()
        bytes[offset] = 255
        var checksum = crc32_range(bytes, 4, len(bytes) - 4)
        for byte in range(4):
            bytes[len(bytes) - 4 + byte] = UInt8(checksum >> UInt32(8 * byte))
        _reject(bytes, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
