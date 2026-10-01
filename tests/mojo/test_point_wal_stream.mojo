from akasha.document.point_state import PointMutation
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.vector_schema import FieldCatalog
from akasha.storage.checksum import BinaryWriter, crc32_range
from akasha.storage.field_catalog import decode_field_catalog_bytes
from akasha.storage.filesystem import (
    append_file_sync,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.point_wal import (
    FieldWalReader,
    RecoveredWalEnvelope,
    encode_point_batch,
)
from akasha.storage.wal import (
    WalRecord,
    encode_batch,
    encode_delete,
    encode_document_upsert,
    repair_wal_tail,
)
from std.memory import ArcPointer, bitcast
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def _catalog() raises -> ArcPointer[FieldCatalog]:
    return ArcPointer(
        decode_field_catalog_bytes(
            read_file_bytes("tests/fixtures/field-catalog/named-f32-v2.bin")
        )
    )


def _fixture() raises -> List[UInt8]:
    return read_file_bytes("tests/fixtures/field-envelopes/combined-wal-v4.bin")


def _legacy() raises -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_u32(0x4C574B41)
    writer.write_u16(1)
    writer.write_u8(1)
    writer.write_u8(0)
    writer.write_u32(48)
    writer.write_u64(1)
    writer.write_i64(-42)
    writer.write_u32(3)
    writer.write_u32(
        0x7FC00001
    )  # Preserve legacy low-level non-finite compatibility.
    writer.write_f32(2)
    writer.write_f32(3)
    var first = writer.take_bytes()
    var checksum = crc32_range(first, 4, len(first))
    writer.write_bytes(first)
    writer.write_u32(checksum)
    var payload: List[DocumentField] = [
        DocumentField("text", PayloadValue.string("old"))
    ]
    writer.write_bytes(encode_document_upsert(2, 1, 3, [1, 2, 3], payload))
    var records: List[WalRecord] = [
        WalRecord.delete(3, -42),
        WalRecord.upsert(4, 2, [5, 6, 7]),
    ]
    writer.write_bytes(encode_batch(3, records))
    return writer.take_bytes()


def _mixed() raises -> List[UInt8]:
    var bytes = _legacy()
    var next = _fixture()
    bytes.extend(Span(next))
    return bytes^


def _length(bytes: List[UInt8], offset: Int) -> Int:
    var value = UInt32(0)
    for i in range(4):
        value |= UInt32(bytes[offset + 8 + i]) << UInt32(i * 8)
    return Int(value)


def _next(mut reader: FieldWalReader) raises -> RecoveredWalEnvelope:
    var envelope = reader.read_next()
    assert_true(Bool(envelope))
    return envelope.take()


def test_mixed_reader_keeps_legacy_and_field_batches_owned_and_distinct() raises:
    var path = String("/tmp/akasha-point-wal-mixed.bin")
    var catalog = _catalog()
    var bytes = _mixed()
    write_file_sync(path, bytes)
    var reader = FieldWalReader(path, catalog.copy())
    var first = _next(reader)
    assert_equal(first.format_version, 1)
    assert_true(first.is_legacy())
    assert_equal(
        bitcast[DType.uint32](first.legacy_records()[0].values[0]),
        UInt32(0x7FC00001),
    )
    var second = _next(reader)
    assert_equal(second.format_version, 2)
    var third = _next(reader)
    assert_equal(third.format_version, 3)
    assert_equal(len(third.legacy_records()), 2)
    var fourth = _next(reader)
    assert_false(fourth.is_legacy())
    assert_equal(fourth.point_batch().first_sequence, UInt64(8))
    assert_equal(reader.valid_length, len(bytes))
    assert_false(Bool(reader.read_next()))
    assert_false(Bool(reader.read_next()))
    assert_equal(second.legacy_records()[0].fields[0].value.as_string(), "old")
    with assert_raises():
        _ = fourth.legacy_records()
    with assert_raises():
        _ = first.point_batch()
    var legacy_address = Int(first.legacy_records()[0].values.unsafe_ptr())
    var point_address = Int(
        fourth.point_batch()
        .mutations[0]
        .field_at(0)
        .value()
        .dense_values[DType.float32]()
        .unsafe_ptr()
    )
    var records = first^.take_legacy_records()
    assert_equal(records[0].id, -42)
    assert_equal(Int(records[0].values.unsafe_ptr()), legacy_address)
    var batch = fourth^.take_point_batch()
    assert_equal(len(batch.mutations), 4)
    assert_equal(
        Int(
            batch.mutations[0]
            .field_at(0)
            .value()
            .dense_values[DType.float32]()
            .unsafe_ptr()
        ),
        point_address,
    )
    remove_file_if_exists(path)


def test_every_mixed_wal_cut_emits_only_whole_envelopes_without_repair() raises:
    var path = String("/tmp/akasha-point-wal-cuts.bin")
    var bytes = _mixed()
    var boundaries = List[Int]()
    var offset = 0
    while offset < len(bytes):
        offset += _length(bytes, offset)
        boundaries.append(offset)
    var catalog = _catalog()
    for cut in range(len(bytes) + 1):
        with open(path, "w") as file:
            file.write_all(Span(bytes)[:cut])
        var reader = FieldWalReader(path, catalog.copy())
        var count = 0
        while True:
            var next = reader.read_next()
            if not next:
                break
            count += 1
        var accepted = 0
        var expected = 0
        for boundary in boundaries:
            if boundary <= cut:
                accepted = boundary
                expected += 1
        assert_equal(count, expected)
        assert_equal(reader.valid_length, accepted)
        assert_equal(reader.source_length, cut)
        assert_equal(len(read_file_bytes(path)), cut)
    remove_file_if_exists(path)


def test_late_corruption_poisoning_preserves_accepted_prefix() raises:
    var path = String("/tmp/akasha-point-wal-corrupt.bin")
    var bytes = _mixed()
    bytes[len(bytes) - 1] ^= 1
    var catalog = _catalog()
    write_file_sync(path, bytes)
    var reader = FieldWalReader(path, catalog.copy())
    for _ in range(3):
        _ = reader.read_next()
    var prefix = reader.valid_length
    with assert_raises():
        _ = reader.read_next()
    with assert_raises():
        _ = reader.read_next()
    assert_equal(reader.valid_length, prefix)
    assert_equal(prefix, len(_legacy()))
    assert_equal(read_file_bytes(path), bytes)
    remove_file_if_exists(path)


def test_cutover_and_shared_sequence_order_reject_invalid_mixed_logs() raises:
    var path = String("/tmp/akasha-point-wal-order.bin")
    var catalog = _catalog()
    var invalids = List[List[UInt8]]()
    invalids.append(encode_delete(8, 1, 3))  # Legacy mutation after cutover.
    var after_new = _fixture()
    var old = encode_delete(7, 1, 3)
    after_new.extend(Span(old))
    invalids.append(after_new^)
    var duplicate = _fixture()
    var again = _fixture()
    duplicate.extend(Span(again))
    invalids.append(duplicate^)
    var crossed = List[WalRecord]()
    crossed.append(WalRecord.delete(7, 1))
    crossed.append(WalRecord.delete(8, 1))
    invalids.append(encode_batch(3, crossed))
    for index in range(len(invalids)):
        write_file_sync(path, invalids[index])
        var reader = FieldWalReader(path, catalog.copy())
        with assert_raises():
            while True:
                var next = reader.read_next()
                if not next:
                    break
    remove_file_if_exists(path)


def test_torn_header_validation_and_unknown_version_do_not_allocate_claimed_body() raises:
    var path = String("/tmp/akasha-point-wal-header.bin")
    var catalog = _catalog()
    var full = _fixture()
    for size in [0, 63, 268_435_457, Int(UInt32.MAX)]:
        var header = List[UInt8]()
        header.extend(Span(full)[:32])
        for i in range(4):
            header[8 + i] = UInt8(UInt32(size) >> UInt32(i * 8))
        write_file_sync(path, header)
        var reader = FieldWalReader(path, catalog.copy())
        with assert_raises():
            _ = reader.read_next()
        assert_equal(reader.valid_length, 0)
        assert_true(reader.buffer_capacity() <= 64 * 1024)
    for bad_version in [UInt8(4), UInt8(5)]:
        var bytes = _fixture()
        bytes[4] = bad_version
        bytes[7] = 255
        var prefix = List[UInt8]()
        prefix.extend(Span(bytes)[:39])
        write_file_sync(path, prefix)
        var torn = FieldWalReader(path, catalog.copy())
        assert_false(Bool(torn.read_next()))
        write_file_sync(path, bytes)
        var complete = FieldWalReader(path, catalog.copy())
        with assert_raises():
            _ = complete.read_next()
    remove_file_if_exists(path)


def test_buffer_growth_is_bounded_and_decoded_payload_survives_refills() raises:
    var path = String("/tmp/akasha-point-wal-bounds.bin")
    var catalog = _catalog()
    var largest = 0
    with open(path, "w") as file:
        for index in range(3002):
            var width = 150_000 if index == 1 else (65_000 if index == 0 else 0)
            var payload: List[DocumentField] = [
                DocumentField("x", PayloadValue.string("v" * width))
            ]
            var mutations: List[PointMutation] = [
                PointMutation(1, 1, [], Optional(payload^))
            ]
            var bytes = encode_point_batch(
                UInt64(index + 8), mutations, catalog[]
            )
            largest = max(largest, len(bytes))
            file.write_all(Span(bytes))
    var reader = FieldWalReader(path, catalog.copy())
    var first = _next(reader)
    var second = _next(reader)
    var count = 2
    while True:
        var next = reader.read_next()
        if not next:
            break
        count += 1
        assert_true(reader.buffer_capacity() <= 2 * max(64 * 1024, largest))
    assert_equal(count, 3002)
    assert_equal(reader.valid_length, reader.source_length)
    assert_equal(
        first.point_batch().mutations[0].payload()[0].value.as_string(),
        "v" * 65_000,
    )
    assert_equal(
        second.point_batch().mutations[0].payload()[0].value.as_string(),
        "v" * 150_000,
    )
    remove_file_if_exists(path)


def test_deferred_repair_then_append_preserves_complete_v4_batch() raises:
    var path = String("/tmp/akasha-point-wal-repair.bin")
    var catalog = _catalog()
    var bytes = _fixture()
    write_file_sync(path, bytes)
    append_file_sync(path, [UInt8(0x41), 0x4B])
    var reader = FieldWalReader(path, catalog.copy())
    _ = reader.read_next()
    assert_false(Bool(reader.read_next()))
    assert_equal(len(read_file_bytes(path)), len(bytes) + 2)
    repair_wal_tail(path, reader.valid_length, reader.source_length)
    assert_equal(read_file_bytes(path), bytes)
    var mutations: List[PointMutation] = [PointMutation.delete(-42)]
    append_file_sync(path, encode_point_batch(12, mutations, catalog[]))
    var reopened = FieldWalReader(path, catalog.copy())
    _ = reopened.read_next()
    assert_equal(
        reopened.read_next().value().point_batch().first_sequence, UInt64(12)
    )
    assert_false(Bool(reopened.read_next()))
    remove_file_if_exists(path)


def test_missing_empty_and_changed_files() raises:
    var path = String("/tmp/akasha-point-wal-files.bin")
    var catalog = _catalog()
    remove_file_if_exists(path)
    var missing = FieldWalReader(path, catalog.copy())
    assert_false(Bool(missing.read_next()))
    assert_false(path_exists(path))
    write_file_sync(path, [])
    var empty = FieldWalReader(path, catalog.copy())
    assert_false(Bool(empty.read_next()))
    write_file_sync(path, _fixture())
    var shrinking = FieldWalReader(path, catalog.copy())
    write_file_sync(path, [])
    with assert_raises():
        _ = shrinking.read_next()
    with assert_raises():
        _ = shrinking.read_next()
    assert_equal(shrinking.valid_length, 0)
    remove_file_if_exists(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
