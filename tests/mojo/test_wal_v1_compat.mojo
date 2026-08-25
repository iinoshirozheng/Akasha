from akasha.document import DocumentField, PayloadValue
from akasha.storage.checksum import BinaryWriter, crc32_range
from akasha.storage.wal import decode_wal_bytes, encode_document_upsert
from std.testing import assert_equal, TestSuite


def _encode_v1_upsert(
    sequence: UInt64, id: Int, values: List[Float32]
) -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_u8(0x41)
    writer.write_u8(0x4B)
    writer.write_u8(0x57)
    writer.write_u8(0x4C)
    writer.write_u16(1)
    writer.write_u8(1)
    writer.write_u8(0)
    writer.write_u32(UInt32(36 + len(values) * 4))
    writer.write_u64(sequence)
    writer.write_i64(Int64(id))
    writer.write_u32(UInt32(len(values)))
    for value in values:
        writer.write_f32(value)
    var body = writer.take_bytes()
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def test_v1_wal_recovers_empty_payload() raises:
    var v1 = _encode_v1_upsert(1, 10, [1.0, 2.0])

    var records = decode_wal_bytes(v1^, 2)

    assert_equal(len(records), 1)
    assert_equal(records[0].id, 10)
    assert_equal(len(records[0].fields), 0)


def test_wal_replays_v1_then_v2_records() raises:
    var v1 = _encode_v1_upsert(1, 10, [1.0])
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("new")))
    var v2 = encode_document_upsert(2, 20, 1, [2.0], fields)
    var combined = List[UInt8]()
    for byte in v1:
        combined.append(byte)
    for byte in v2:
        combined.append(byte)

    var records = decode_wal_bytes(combined^, 1)

    assert_equal(len(records), 2)
    assert_equal(len(records[0].fields), 0)
    assert_equal(records[1].fields[0].value.as_string(), "new")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
