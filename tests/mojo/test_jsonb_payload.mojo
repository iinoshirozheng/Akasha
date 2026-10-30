from akasha.document import JsonbValue, PayloadValue, DocumentField
from akasha.document.codec import encode_payload, decode_payload, MAX_PAYLOAD_BYTES
from akasha.storage.filesystem import read_file_bytes
from akasha.storage.checksum import BinaryWriter
from test_jsonb import _fixture, _unhex
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite


def _roundtrip(value: PayloadValue) raises:
    var fields: List[DocumentField] = [DocumentField("x", value.clone())]
    var bytes = encode_payload(fields)
    assert_equal(bytes[4], UInt8(3))
    var result = decode_payload(Span(bytes))
    bytes.clear()
    assert_true(result[0].value.same_representation(value))
    assert_equal(result[0].value.node_count(), value.node_count())
    assert_equal(result[0].value._depth, value._depth)


def test_all_source_jsonb_bodies_preserved_by_payload_v3() raises:
    var fixture = _fixture()
    var count = 0
    for category in ["cases", "legacy"]:
        for row in fixture[category]:
            var bytes = _unhex(row["hex"])
            var value = PayloadValue.jsonb(JsonbValue(Span(bytes)))
            assert_equal(value.as_jsonb().to_bytes(), bytes)
            _roundtrip(value)
            if value._depth <= 62:
                var array = PayloadValue.array([PayloadValue.null(), value.clone(), PayloadValue.integer(7)])
                var object = PayloadValue.object(["nested", "after"], [array^, PayloadValue.boolean(True)])
                _roundtrip(object)
                assert_equal(object.get_key("nested").value().get_index(1).value().as_jsonb().to_bytes(), bytes)
                assert_equal(object.get_key("after").value().as_bool(), True)
            count += 1
    assert_equal(count, 6331)


def _golden_value() raises -> PayloadValue:
    return PayloadValue.array([
        PayloadValue.null(), PayloadValue.jsonb(JsonbValue.null()),
        PayloadValue.object(["jsonb", "plain"], [
            PayloadValue.jsonb(JsonbValue.timestamp_tz(-1, 28800)),
            PayloadValue.floating(-0.0)]),
    ])


def test_independent_v3_fixture_and_frozen_v1_v2_upgrade() raises:
    var golden = read_file_bytes("tests/fixtures/payload/v3.bin")
    var expected = _golden_value()
    var fields: List[DocumentField] = [DocumentField("x", expected.clone())]
    assert_equal(encode_payload(fields), golden)
    assert_true(decode_payload(golden^)[0].value.same_representation(expected))
    for version in [1, 2]:
        var frozen = read_file_bytes("tests/fixtures/payload/v" + String(version) + ".bin")
        var decoded = decode_payload(frozen.copy())
        assert_equal(encode_payload(decoded, version=version), frozen)
        var migrated = encode_payload(decoded)
        assert_equal(migrated[4], UInt8(3))
        assert_true(decode_payload(migrated^)[0].value.same_representation(decoded[0].value))
        with assert_raises():
            _ = encode_payload(fields, version=version)
    var downgraded = encode_payload(fields)
    downgraded[4] = 2
    with assert_raises():
        _ = decode_payload(downgraded^)


def test_storage_null_jsonb_null_and_owned_subtrees() raises:
    var body = JsonbValue.string("owned").to_bytes()
    var value = PayloadValue.jsonb(JsonbValue(Span(body)))
    body.clear()
    var array = PayloadValue.array([PayloadValue.null(), PayloadValue.jsonb(JsonbValue.null()), value^])
    assert_false(array.get_index(0).value().same_representation(array.get_index(1).value()))
    assert_true(array.get_index(0).value().is_null())
    assert_true(array.get_index(1).value().is_jsonb())
    assert_false(Bool(array.get_index(3)))
    var copied = array.clone()
    var children = array.children()
    array = PayloadValue.null()
    assert_true(array.is_null())
    assert_equal(children[2].as_jsonb().as_string(), "owned")
    assert_equal(copied.get_index(2).value().as_jsonb().as_string(), "owned")
    var exposed = copied.get_index(2).value().as_jsonb()
    exposed = JsonbValue.null()
    assert_equal(exposed.kind(), 5)
    assert_equal(copied.get_index(2).value().as_jsonb().as_string(), "owned")


def test_mixed_container_depth_survives_extraction_and_reinsertion() raises:
    var value = JsonbValue.null()
    for _ in range(62):
        value = JsonbValue.array([value.copy()])
    var inner = PayloadValue.array([PayloadValue.jsonb(value^)])
    var outer = PayloadValue.object(["x"], [inner^])
    assert_equal(outer._depth, 64)
    var extracted = outer.get_key("x").value().clone()
    assert_equal(extracted._depth, 63)
    _roundtrip(outer)
    var rebuilt = PayloadValue.array([extracted.clone()])
    assert_equal(rebuilt._depth, 64)
    with assert_raises():
        _ = PayloadValue.array([rebuilt^])

    # Construct an over-deep wire value without using the checked constructors.
    var writer = BinaryWriter()
    writer.write_u32(UInt32.MAX)
    writer.write_u16(3)
    writer.write_u16(0)
    writer.write_u32(1)
    writer.write_u16(1)
    writer.write_u8(120)
    for _ in range(3):
        writer.write_u8(6)
        writer.write_u32(1)
    var body = extracted.get_index(0).value().as_jsonb().to_bytes()
    writer.write_u8(9)
    writer.write_u32(UInt32(len(body)))
    writer.write_bytes(body)
    with assert_raises(contains="depth"):
        _ = decode_payload(writer.take_bytes())


def test_jsonb_internal_nodes_and_encoded_bytes_share_payload_limits() raises:
    var array = List[UInt8](length=4 + 4 * (JsonbValue.MAX_NODES - 1), fill=0)
    array[0] = 0x80
    array[2] = 0xff
    array[3] = 0xff
    var maximum = PayloadValue.jsonb(JsonbValue(Span(array)))
    assert_equal(maximum.node_count(), PayloadValue.MAX_NODES)
    _roundtrip(maximum)
    with assert_raises(contains="node count"):
        _ = PayloadValue.array([maximum.clone()])
    var fields: List[DocumentField] = [DocumentField("x", maximum.clone()), DocumentField("y", PayloadValue.null())]
    with assert_raises(contains="node count"):
        _ = encode_payload(fields)

    var one: List[DocumentField] = [DocumentField("x", maximum.clone())]
    var forged = encode_payload(one)
    forged[8] = 2
    forged.extend([UInt8(1), 0, 121, 5])
    with assert_raises(contains="node count"):
        _ = decode_payload(forged^)

    # Exactly 16 MiB including the outer header/name/tag/length and JSONB body.
    var binary = List[UInt8](length=MAX_PAYLOAD_BYTES - 29, fill=1)
    var bounded: List[DocumentField] = [DocumentField("x", PayloadValue.jsonb(JsonbValue.binary(Span(binary))))]
    var bytes = encode_payload(bounded)
    assert_equal(len(bytes), MAX_PAYLOAD_BYTES)
    assert_equal(decode_payload(bytes^)[0].value.content_bytes(), MAX_PAYLOAD_BYTES - 20)
    binary.append(1)
    var oversized: List[DocumentField] = [DocumentField("x", PayloadValue.jsonb(JsonbValue.binary(Span(binary))))]
    with assert_raises(contains="size limit"):
        _ = encode_payload(oversized)


def test_v3_rejects_truncation_bad_jsonb_lengths_tags_and_utf8() raises:
    var golden = read_file_bytes("tests/fixtures/payload/v3.bin")
    for end in range(len(golden)):
        with assert_raises():
            _ = decode_payload(Span(golden)[:end])
    golden.append(0)
    with assert_raises():
        _ = decode_payload(golden^)
    var fields: List[DocumentField] = [DocumentField("x", PayloadValue.jsonb(JsonbValue.string("x"))) ]
    var valid = encode_payload(fields)
    # Tag at 15, body length at 16, JSONB header at 20, jentry at 24, UTF-8 at 28.
    for offset in [4, 6, 15, 16, 20, 24, 28]:
        var bad = valid.copy()
        bad[offset] = 255
        with assert_raises():
            _ = decode_payload(bad^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
