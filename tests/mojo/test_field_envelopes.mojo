from akasha.document.point_state import (
    PointMutation,
    PointState,
    apply_point_mutation,
)
from akasha.document.vector_schema import FieldCatalog
from akasha.storage.checksum import crc32_range
from akasha.storage.field_catalog import decode_field_catalog_bytes
from akasha.storage.filesystem import read_file_bytes
from akasha.storage.point_wal import decode_point_batch, encode_point_batch
from akasha.storage.point_segment import (
    decode_point_segment,
    encode_point_segment,
)
from akasha.storage.segment import decode_segment_bytes
from akasha.storage.wal import decode_wal_bytes
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def _catalog(matrix: Bool = False) raises -> FieldCatalog:
    var name = "type-matrix-v2.bin" if matrix else "named-f32-v2.bin"
    return decode_field_catalog_bytes(
        read_file_bytes("tests/fixtures/field-catalog/" + name)
    )


def _fixture(name: String) raises -> List[UInt8]:
    return read_file_bytes("tests/fixtures/field-envelopes/" + name)


def _u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for i in range(4):
        bytes[offset + i] = UInt8(value >> UInt32(i * 8))


def _u64(mut bytes: List[UInt8], offset: Int, value: UInt64):
    for i in range(8):
        bytes[offset + i] = UInt8(value >> UInt64(i * 8))


def _crc(mut bytes: List[UInt8]):
    _u32(bytes, len(bytes) - 4, crc32_range(bytes, 4, len(bytes) - 4))


def test_wal_fixture_decodes_atomic_combined_patches_and_repeated_ids() raises:
    var catalog = _catalog()
    var bytes = _fixture("combined-wal-v4.bin")
    var batch = decode_point_batch(Span(bytes), catalog)
    assert_equal(batch.first_sequence, UInt64(8))
    assert_equal(batch.last_sequence(), UInt64(11))
    assert_equal(len(batch.mutations), 4)
    assert_equal(
        encode_point_batch(batch.first_sequence, batch.mutations, catalog),
        bytes,
    )
    bytes.clear()
    var initial = apply_point_mutation(
        Optional[PointState](), batch.mutations[0], 8, catalog
    )
    var patched = apply_point_mutation(
        Optional(initial.copy()), batch.mutations[1], 9, catalog
    )
    assert_equal(patched.sequence, UInt64(9))
    assert_equal(patched.document_sequence, UInt64(8))
    assert_equal(patched.field_count(), 3)
    assert_equal(patched.ordinal_for(2), -1)
    assert_equal(patched.field_at(2).id, 7)
    assert_equal(
        patched.field_at(2).value().dense_values[DType.float32]()[3], Float32(9)
    )
    assert_equal(initial.field_at(0).address(), patched.field_at(0).address())
    assert_equal(batch.mutations[2].id, Int.MIN)
    assert_equal(batch.mutations[3].id, Int.MAX)
    assert_true(batch.mutations[3].replaces_payload())
    assert_equal(len(batch.mutations[3].payload()), 0)


def test_segment_golden_bases_deltas_and_typed_records_reencode_exactly() raises:
    var names: List[String] = [
        "base-v4.bin",
        "delta-v4.bin",
        "typed-base-v4.bin",
        "empty-base-v4.bin",
    ]
    for i in range(len(names)):
        var catalog = _catalog(i >= 2)
        var bytes = _fixture(names[i])
        var segment = decode_point_segment(Span(bytes), catalog)
        assert_equal(
            encode_point_segment(
                segment.kind,
                segment.min_sequence,
                segment.last_sequence,
                segment.points,
                catalog,
            ),
            bytes,
        )
    var catalog = _catalog()
    var delta = decode_point_segment(_fixture("delta-v4.bin"), catalog)
    assert_equal(delta.kind, 2)
    assert_equal(delta.min_sequence, UInt64(8))
    assert_equal(delta.last_sequence, UInt64(11))
    assert_true(delta.points[0].tombstone)
    assert_equal(delta.points[0].id, Int.MIN)
    assert_equal(delta.points[1].document_sequence, UInt64(8))
    assert_false(Bool(delta.points[2].legacy_document()))


def test_envelopes_reject_every_truncation_byte_flip_and_trailing_byte() raises:
    var names: List[String] = [
        "combined-wal-v4.bin",
        "last-sequence-wal-v4.bin",
        "base-v4.bin",
        "delta-v4.bin",
        "typed-base-v4.bin",
        "empty-base-v4.bin",
    ]
    for index in range(len(names)):
        var catalog = _catalog(index == 1 or index >= 4)
        var original = _fixture(names[index])
        for count in range(len(original)):
            with assert_raises():
                if index < 2:
                    _ = decode_point_batch(Span(original)[:count], catalog)
                else:
                    _ = decode_point_segment(Span(original)[:count], catalog)
        for offset in range(len(original)):
            var bytes = original.copy()
            bytes[offset] ^= 1
            with assert_raises():
                if index < 2:
                    _ = decode_point_batch(bytes, catalog)
                else:
                    _ = decode_point_segment(bytes, catalog)
        var trailing = original.copy()
        trailing.append(0)
        with assert_raises():
            if index < 2:
                _ = decode_point_batch(trailing, catalog)
            else:
                _ = decode_point_segment(trailing, catalog)


def test_wal_crc_valid_bad_headers_late_fields_and_payload_are_rejected() raises:
    var catalog = _catalog()
    for offset in [4, 6, 7, 24, 32, 36, 48, 49, 50, 96, 97, 98, 136, 152, 164]:
        var bytes = _fixture("combined-wal-v4.bin")
        bytes[offset] = 255
        _crc(bytes)
        with assert_raises():
            _ = decode_point_batch(bytes, catalog)
    for offset in [8, 20, 52, 56, 60, 68, 76, 100, 116, 140, 144, 156, 168]:
        var bytes = _fixture("combined-wal-v4.bin")
        _u32(bytes, offset, UInt32.MAX)
        _crc(bytes)
        with assert_raises():
            _ = decode_point_batch(bytes, catalog)
    var late = _fixture("combined-wal-v4.bin")
    _u32(
        late, 160, 3
    )  # Unknown field in the second mutation, after a valid first.
    _crc(late)
    with assert_raises():
        _ = decode_point_batch(late, catalog)
    var duplicate = _fixture("combined-wal-v4.bin")
    _u32(duplicate, 108, 1)
    _crc(duplicate)
    with assert_raises():
        _ = decode_point_batch(duplicate, catalog)
    var phantom_delete_body = _fixture("combined-wal-v4.bin")
    phantom_delete_body[48] = 2
    _crc(phantom_delete_body)
    with assert_raises():
        _ = decode_point_batch(phantom_delete_body, catalog)


def test_wal_sequence_cutover_overflow_and_count_limits() raises:
    var catalog = _catalog()
    for sequence in [UInt64(0), UInt64(7), UInt64.MAX - 2]:
        var bytes = _fixture("combined-wal-v4.bin")
        _u64(bytes, 12, sequence)
        _crc(bytes)
        with assert_raises():
            _ = decode_point_batch(bytes, catalog)
    with assert_raises():
        _ = decode_point_batch(_fixture("combined-wal-v4.bin"), catalog, 8)
    var max_catalog = _catalog(True)
    var bytes = _fixture("last-sequence-wal-v4.bin")
    var batch = decode_point_batch(bytes, max_catalog)
    assert_equal(batch.last_sequence(), UInt64.MAX)
    assert_equal(
        encode_point_batch(batch.first_sequence, batch.mutations, max_catalog),
        bytes,
    )
    var mutations = List[PointMutation]()
    with assert_raises():
        _ = encode_point_batch(8, mutations, catalog)
    for _ in range(65_536):
        mutations.append(PointMutation.delete(-1))
    var largest = encode_point_batch(8, mutations, catalog)
    var decoded = decode_point_batch(largest, catalog)
    assert_equal(len(decoded.mutations), 65_536)
    assert_equal(decoded.last_sequence(), UInt64(65_543))
    mutations.append(PointMutation.delete(-1))
    with assert_raises():
        _ = encode_point_batch(8, mutations, catalog)


def test_segment_crc_valid_bad_metadata_intervals_ids_and_base_tombstones() raises:
    var catalog = _catalog()
    for offset in [4, 6, 8, 16, 20]:
        var bytes = _fixture("base-v4.bin")
        bytes[offset] = 255
        _crc(bytes)
        with assert_raises():
            _ = decode_point_segment(bytes, catalog)
    for offset in [24, 32]:
        var bytes = _fixture("base-v4.bin")
        _u64(bytes, offset, UInt64.MAX)
        _crc(bytes)
        with assert_raises():
            _ = decode_point_segment(bytes, catalog)
    var invalid_range = _fixture("base-v4.bin")
    _u64(invalid_range, 40, 8)
    _crc(invalid_range)
    with assert_raises():
        _ = decode_point_segment(invalid_range, catalog)
    var invalid_ids = _fixture("base-v4.bin")
    _u64(invalid_ids, 56, 1)
    _crc(invalid_ids)
    with assert_raises():
        _ = decode_point_segment(invalid_ids, catalog)
    var invalid_base = _fixture("delta-v4.bin")
    invalid_base[6] = 1
    _u64(invalid_base, 32, 0)
    _crc(invalid_base)
    with assert_raises():
        _ = decode_point_segment(invalid_base, catalog)
    var trailing = _fixture("base-v4.bin")
    _u64(trailing, 24, 2)
    _crc(trailing)
    with assert_raises():
        _ = decode_point_segment(trailing, catalog)


def test_catalog_binding_and_legacy_reader_rejection() raises:
    var catalog = _catalog()
    var other = _catalog(True)
    with assert_raises():
        _ = decode_point_batch(_fixture("combined-wal-v4.bin"), other)
    with assert_raises():
        _ = decode_point_segment(_fixture("base-v4.bin"), other)
    # The same revision cannot hide a change to fields with equal byte widths.
    var changed = decode_field_catalog_bytes(
        read_file_bytes("tests/fixtures/field-catalog/named-f32-v2.bin")
    )
    changed.legacy_cutover_sequence = 6
    with assert_raises():
        _ = decode_point_batch(_fixture("combined-wal-v4.bin"), changed)
    with assert_raises():
        _ = decode_point_segment(_fixture("base-v4.bin"), changed)
    with assert_raises():
        _ = decode_wal_bytes(_fixture("combined-wal-v4.bin"), 3)
    with assert_raises():
        _ = decode_segment_bytes(_fixture("base-v4.bin"), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
