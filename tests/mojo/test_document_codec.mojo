from akasha.document import DocumentField, PayloadValue
from akasha.document.codec import decode_payload, encode_payload
from akasha.storage.checksum import BinaryWriter
from std.math import inf
from std.memory import bitcast
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    TestSuite,
)


def _field_prefix() -> BinaryWriter:
    var writer = BinaryWriter()
    writer.write_u32(1)
    writer.write_u16(1)
    writer.write_u8(0x78)  # x
    return writer^


def test_payload_codec_round_trips_all_types_in_order() raises:
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("Akasha")))
    fields.append(DocumentField("page", PayloadValue.integer(-7)))
    fields.append(DocumentField("score", PayloadValue.floating(0.75)))
    fields.append(DocumentField("active", PayloadValue.boolean(True)))

    var bytes = encode_payload(fields)
    var decoded = decode_payload(bytes^)

    assert_equal(len(decoded), 4)
    assert_equal(decoded[0].name, "chunk")
    assert_equal(decoded[0].value.as_string(), "Akasha")
    assert_equal(decoded[1].value.as_int(), Int64(-7))
    assert_almost_equal(decoded[2].value.as_float(), 0.75, atol=1.0e-12)
    assert_equal(decoded[3].value.as_bool(), True)


def test_payload_codec_round_trips_empty_fields() raises:
    var fields = List[DocumentField]()
    var bytes = encode_payload(fields)
    var decoded = decode_payload(bytes^)

    assert_equal(len(decoded), 0)


def test_payload_encoder_rejects_duplicate_keys() raises:
    var fields = List[DocumentField]()
    fields.append(DocumentField("source", PayloadValue.string("a")))
    fields.append(DocumentField("source", PayloadValue.string("b")))

    with assert_raises():
        _ = encode_payload(fields)


def test_payload_decoder_rejects_invalid_utf8_and_unknown_tag() raises:
    var invalid_utf8 = BinaryWriter()
    invalid_utf8.write_u32(1)
    invalid_utf8.write_u16(1)
    invalid_utf8.write_u8(0xFF)
    invalid_utf8.write_u8(4)
    invalid_utf8.write_u8(1)
    var invalid_utf8_bytes = invalid_utf8.take_bytes()
    with assert_raises():
        _ = decode_payload(invalid_utf8_bytes^)

    var unknown = _field_prefix()
    unknown.write_u8(99)
    var unknown_bytes = unknown.take_bytes()
    with assert_raises():
        _ = decode_payload(unknown_bytes^)


def test_payload_decoder_rejects_invalid_bool_and_non_finite_float() raises:
    var invalid_bool = _field_prefix()
    invalid_bool.write_u8(4)
    invalid_bool.write_u8(2)
    var invalid_bool_bytes = invalid_bool.take_bytes()
    with assert_raises():
        _ = decode_payload(invalid_bool_bytes^)

    var invalid_float = _field_prefix()
    invalid_float.write_u8(3)
    invalid_float.write_u64(bitcast[DType.uint64](inf[DType.float64]()))
    var invalid_float_bytes = invalid_float.take_bytes()
    with assert_raises():
        _ = decode_payload(invalid_float_bytes^)


def test_payload_decoder_rejects_truncation_and_limits() raises:
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("text")))
    var truncated = encode_payload(fields)
    _ = truncated.pop()
    with assert_raises():
        _ = decode_payload(truncated^)

    var too_many = BinaryWriter()
    too_many.write_u32(1025)
    var too_many_bytes = too_many.take_bytes()
    with assert_raises():
        _ = decode_payload(too_many_bytes^)

    var oversized = List[UInt8](length=16 * 1024 * 1024 + 1, fill=0)
    with assert_raises():
        _ = decode_payload(oversized^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
