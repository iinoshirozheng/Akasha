from akasha.storage.checksum import BinaryWriter, crc32_range
from akasha.storage.segment import (
    decode_segment_bytes,
    SEGMENT_KIND_BASE,
)
from std.testing import assert_equal, TestSuite


def _encode_v1_segment() -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_u8(0x41)
    writer.write_u8(0x4B)
    writer.write_u8(0x53)
    writer.write_u8(0x47)
    writer.write_u16(1)
    writer.write_u16(0)
    writer.write_u32(2)
    writer.write_u64(1)
    writer.write_u64(7)
    writer.write_i64(42)
    writer.write_u64(7)
    writer.write_f32(1.0)
    writer.write_f32(2.0)
    var body = writer.take_bytes()
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def test_v1_segment_recovers_vector_with_empty_payload() raises:
    var bytes = _encode_v1_segment()

    var snapshot = decode_segment_bytes(bytes^, 2)

    assert_equal(snapshot.format_version, 1)
    assert_equal(snapshot.kind, SEGMENT_KIND_BASE)
    assert_equal(snapshot.min_sequence, UInt64(0))
    assert_equal(snapshot.last_sequence, UInt64(7))
    assert_equal(len(snapshot.entries), 1)
    assert_equal(snapshot.entries[0].id, 42)
    assert_equal(snapshot.entries[0].values[1], Float32(2.0))
    assert_equal(len(snapshot.entries[0].fields), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
