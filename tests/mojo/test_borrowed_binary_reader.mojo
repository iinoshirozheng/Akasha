from akasha.document.codec import decode_payload, encode_payload
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.storage.checksum import (
    BorrowedBinaryReader,
    BinaryReader,
    BinaryWriter,
)
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def _check_values(bytes: List[UInt8]) raises:
    var reader = BorrowedBinaryReader(Span(bytes))
    assert_equal(reader.read_u8(), UInt8(0xAB))
    assert_equal(reader.read_u16(), UInt16(0x1234))
    assert_equal(reader.read_u32(), UInt32(0x89ABCDEF))
    assert_equal(reader.read_u64(), UInt64.MAX)
    assert_equal(reader.read_i64(), Int64.MIN)
    assert_equal(bitcast[DType.uint32](reader.read_f32()), UInt32(0x80000000))
    assert_equal(
        bitcast[DType.uint64](reader.read_f64()), UInt64(0x7FF8000000001234)
    )
    assert_equal(reader.position(), len(bytes) - 3)
    var tail = reader.read_span(3)
    assert_equal(
        Int(tail.unsafe_ptr()), Int(bytes.unsafe_ptr()) + len(bytes) - 3
    )
    assert_equal(String(from_utf8=tail), "abc")
    assert_equal(reader.remaining(), 0)
    assert_equal(len(reader.read_span(0)), 0)


def test_borrowed_reader_preserves_scalar_bits_and_subspan_pointer() raises:
    var writer = BinaryWriter()
    writer.write_u8(0xAB)
    writer.write_u16(0x1234)
    writer.write_u32(0x89ABCDEF)
    writer.write_u64(UInt64.MAX)
    writer.write_i64(Int64.MIN)
    writer.write_u32(0x80000000)
    writer.write_u64(0x7FF8000000001234)
    writer.write_bytes([UInt8(97), UInt8(98), UInt8(99)])
    var bytes = writer.take_bytes()
    _check_values(bytes)
    assert_equal(bytes[0], UInt8(0xAB))


def _check_bounds(bytes: List[UInt8]) raises:
    var reader = BorrowedBinaryReader(Span(bytes))
    _ = reader.read_u8()
    for count in [-1, 4, Int.MAX]:
        with assert_raises():
            _ = reader.read_span(count)
        assert_equal(reader.position(), 1)
    with assert_raises():
        _ = reader.read_u32()
    assert_equal(reader.position(), 1)
    assert_equal(reader.read_u16(), UInt16(0x0302))
    assert_equal(reader.read_u8(), UInt8(4))
    assert_equal(len(reader.read_span(0)), 0)
    with assert_raises():
        _ = reader.read_u8()
    assert_equal(reader.position(), 4)


def test_borrowed_and_owned_bounds_reject_overflow_without_advancing() raises:
    var bytes: List[UInt8] = [1, 2, 3, 4]
    _check_bounds(bytes)
    var owned = BinaryReader(bytes^)
    _ = owned.read_u8()
    for count in [-1, 4, Int.MAX]:
        with assert_raises():
            _ = owned.read_bytes(count)
        assert_equal(owned.position(), 1)
    assert_equal(owned.read_u16(), UInt16(0x0302))


def _decode_offset_payload() raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("欄位", PayloadValue.string("長字串-" * 100)))
    fields.append(DocumentField("n", PayloadValue.integer(Int64.MIN)))
    fields.append(DocumentField("f", PayloadValue.floating(-0.0)))
    fields.append(DocumentField("b", PayloadValue.boolean(True)))
    var encoded = encode_payload(fields)
    var framed: List[UInt8] = [99, 98, 97]
    framed.extend(Span(encoded))
    framed.append(96)
    var decoded = decode_payload(Span(framed)[3 : len(framed) - 1])
    # No source buffer or reader may be retained by the returned owned fields.
    for i in range(len(framed)):
        framed[i] = 0
    return decoded^


def test_payload_span_slice_returns_independent_owned_fields() raises:
    var fields = _decode_offset_payload()
    assert_equal(len(fields), 4)
    assert_equal(fields[0].name, "欄位")
    assert_equal(fields[0].value.as_string(), "長字串-" * 100)
    assert_equal(fields[1].value.as_int(), Int64.MIN)
    assert_equal(
        bitcast[DType.uint64](fields[2].value.as_float()),
        UInt64(0x8000000000000000),
    )
    assert_equal(fields[3].value.as_bool(), True)
    var encoded = encode_payload(fields)
    var owned = decode_payload(encoded.copy())
    var reencoded = encode_payload(owned)
    assert_equal(len(reencoded), len(encoded))
    for i in range(len(encoded)):
        assert_equal(reencoded[i], encoded[i])


def _reject_both(bytes: List[UInt8]) raises:
    with assert_raises():
        _ = decode_payload(bytes.copy())
    with assert_raises():
        _ = decode_payload(Span(bytes))


def test_payload_span_and_owned_decoders_reject_the_same_invalid_bytes() raises:
    _reject_both([])
    _reject_both([UInt8(0), 0, 0])
    _reject_both([UInt8(255), 255, 255, 255])  # Field count limit.
    _reject_both([UInt8(0), 0, 0, 0, 1])  # Trailing byte.
    _reject_both([UInt8(1), 0, 0, 0, 1, 0, 120, 4, 2])  # Invalid bool.
    _reject_both([UInt8(1), 0, 0, 0, 1, 0, 120, 99])  # Unknown kind.
    _reject_both([UInt8(1), 0, 0, 0, 1, 0, 120, 1, 255, 255, 255, 255])
    var empty: List[UInt8] = [0, 0, 0, 0]
    assert_equal(len(decode_payload(Span(empty))), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
