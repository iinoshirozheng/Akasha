from akasha.document.point_codec import (
    decode_point_record,
    encode_point_record,
    decode_vector_value,
    encode_vector_value,
)
from akasha.document.point_state import PointState, PointField
from akasha.document.vector_schema import (
    FieldCatalog,
    VectorFieldSpec,
    legacy_vector_fields,
)
from akasha.document.vector_value import VectorValue
from akasha.storage.field_catalog import decode_field_catalog_bytes
from akasha.storage.filesystem import read_file_bytes
from std.memory import bitcast
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
    return read_file_bytes("tests/fixtures/point-records/" + name)


def _u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for i in range(4):
        bytes[offset + i] = UInt8(value >> UInt32(i * 8))


def test_independent_complete_records_reencode_exactly() raises:
    var names: List[String] = [
        "default-and-named.bin",
        "named-only.bin",
        "payload-only.bin",
        "deleted.bin",
        "type-matrix.bin",
        "empty-multivector.bin",
    ]
    for index in range(len(names)):
        var catalog = _catalog(index >= 4)
        var bytes = _fixture(names[index])
        var record = decode_point_record(Span(bytes), catalog)
        assert_equal(encode_point_record(record, catalog), bytes)
    var catalog = _catalog()
    var record = decode_point_record(_fixture("default-and-named.bin"), catalog)
    assert_equal(record.id, -42)
    assert_equal(record.sequence, UInt64(9))
    assert_equal(record.document_sequence, UInt64(8))
    assert_equal(record.payload()[0].value.as_string(), "old")
    assert_equal(
        bitcast[DType.uint32](
            record.field_at(0).value().dense_values[DType.float32]()[1]
        ),
        UInt32(0x80000000),
    )
    var named = decode_point_record(_fixture("named-only.bin"), catalog)
    assert_equal(named.id, Int.MAX)
    assert_false(Bool(named.legacy_document()))
    assert_equal(named.field_at(2).value().sparse_values()[1].term_id, Int.MAX)
    var deleted = decode_point_record(_fixture("deleted.bin"), catalog)
    assert_equal(deleted.id, Int.MIN)
    assert_true(deleted.tombstone)


def test_native_scalar_bits_and_empty_multi_survive_borrowed_source() raises:
    var catalog = _catalog(True)
    var bytes = _fixture("type-matrix.bin")
    var record = decode_point_record(bytes, catalog)
    bytes.clear()
    assert_equal(
        bitcast[DType.uint16](
            record.field_at(2).value().dense_values[DType.float16]()[4]
        ),
        UInt16(1),
    )
    assert_equal(
        bitcast[DType.uint16](
            record.field_at(3).value().dense_values[DType.bfloat16]()[6]
        ),
        UInt16(0xFF7F),
    )
    assert_equal(
        record.field_at(4).value().dense_values[DType.int8]()[0], Int8(-128)
    )
    assert_equal(
        record.field_at(5).value().dense_values[DType.uint8]()[6], UInt8(255)
    )
    assert_equal(record.field_at(6).value().binary_values()[1], UInt8(1))
    assert_equal(record.field_at(8).value().row_count(), 2)
    assert_equal(
        record.field_at(8).value().multivector_values[DType.float32]()[5],
        Float32(-3),
    )
    assert_equal(
        encode_point_record(record, catalog), _fixture("type-matrix.bin")
    )
    var empty = decode_point_record(_fixture("empty-multivector.bin"), catalog)
    assert_equal(empty.sequence, UInt64.MAX)
    assert_equal(empty.field_at(0).value().row_count(), 0)


def test_all_truncated_and_trailing_point_records_fail() raises:
    var names: List[String] = [
        "default-and-named.bin",
        "named-only.bin",
        "payload-only.bin",
        "deleted.bin",
        "type-matrix.bin",
        "empty-multivector.bin",
    ]
    for index in range(len(names)):
        var catalog = _catalog(index >= 4)
        var bytes = _fixture(names[index])
        for count in range(len(bytes)):
            with assert_raises():
                _ = decode_point_record(Span(bytes)[:count], catalog)
            if count >= 40:
                var internally_truncated = List[UInt8]()
                internally_truncated.extend(Span(bytes)[:count])
                _u32(internally_truncated, 0, UInt32(count))
                with assert_raises():
                    _ = decode_point_record(internally_truncated, catalog)
        bytes.append(0)
        with assert_raises():
            _ = decode_point_record(bytes, catalog)
        _u32(bytes, 0, UInt32(len(bytes)))
        with assert_raises():
            _ = decode_point_record(bytes, catalog)


def test_record_header_and_field_lengths_validate_before_allocation() raises:
    var catalog = _catalog()
    for offset in [0, 24, 32, 36, 59, 63, 79, 83, 91, 95]:
        var bytes = _fixture("default-and-named.bin")
        _u32(bytes, offset, UInt32.MAX)
        with assert_raises():
            _ = decode_point_record(bytes, catalog)
    for offset in [4, 5, 6, 7]:
        var bytes = _fixture("default-and-named.bin")
        bytes[offset] = 255
        with assert_raises():
            _ = decode_point_record(bytes, catalog)
    for sequence in [0, 1, 6]:
        var bytes = _fixture("default-and-named.bin")
        _u32(bytes, 16, UInt32(sequence))
        with assert_raises():
            _ = decode_point_record(bytes, catalog)
    var duplicate = _fixture("default-and-named.bin")
    _u32(duplicate, 91, 0)
    with assert_raises():
        _ = decode_point_record(duplicate, catalog)
    var no_document_version = _fixture("default-and-named.bin")
    _u32(no_document_version, 24, 0)
    with assert_raises():
        _ = decode_point_record(no_document_version, catalog)
    var phantom_document_version = _fixture("named-only.bin")
    _u32(phantom_document_version, 24, 1)
    with assert_raises():
        _ = decode_point_record(phantom_document_version, catalog)
    var tombstone_fields = _fixture("default-and-named.bin")
    tombstone_fields[4] = 2
    with assert_raises():
        _ = decode_point_record(tombstone_fields, catalog)


def _numeric[dtype: DType](scalar: UInt8) raises:
    for kind in [UInt8(0), UInt8(2)]:
        var field = VectorFieldSpec(2, "x", kind, scalar, 0, 0, 3)
        var value: VectorValue
        if kind == 0:
            value = VectorValue.dense[dtype]([0, 1, 2])
        else:
            value = VectorValue.multivector[dtype](3, [0, 1, 2, 3, 4, 5])
        var bytes = encode_vector_value(value, field)
        var decoded = decode_vector_value(Span(bytes), field)
        assert_equal(encode_vector_value(decoded, field), bytes)
        for count in range(len(bytes)):
            with assert_raises():
                _ = decode_vector_value(Span(bytes)[:count], field)
        bytes.append(0)
        with assert_raises():
            _ = decode_vector_value(Span(bytes), field)


def test_dense_and_multivector_codec_covers_all_five_authority_dtypes() raises:
    _numeric[DType.float32](0)
    _numeric[DType.bfloat16](1)
    _numeric[DType.float16](2)
    _numeric[DType.int8](3)
    _numeric[DType.uint8](4)


def test_vector_bodies_reject_overflow_nonfinite_terms_and_padding() raises:
    var sparse = VectorFieldSpec(2, "x", 1, 0, 0, 2, 0)
    var huge: List[UInt8] = [255, 255, 255, 255]
    with assert_raises():
        _ = decode_vector_value(Span(huge), sparse)
    var matrix = VectorFieldSpec(2, "x", 2, 0, 0, 0, Int(UInt32.MAX))
    with assert_raises():
        _ = decode_vector_value(Span(huge), matrix)
    var bits = VectorFieldSpec(2, "x", 3, 5, 3, 0, 9)
    var invalid_bits: List[UInt8] = [0, 2]
    with assert_raises():
        _ = decode_vector_value(Span(invalid_bits), bits)
    var nonfinite: List[UInt8] = [0, 0, 128, 127]
    var dense = VectorFieldSpec(2, "x", 0, 0, 0, 0, 1)
    with assert_raises():
        _ = decode_vector_value(Span(nonfinite), dense)
    var terms: List[UInt8] = [
        1,
        0,
        0,
        0,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        0,
        0,
        128,
        63,
    ]
    with assert_raises():
        _ = decode_vector_value(Span(terms), sparse)


def test_maximum_point_field_count_and_catalog_binding() raises:
    var source = _catalog()
    var specs = legacy_vector_fields(source.field_at(0).hnsw.value())
    var fields: List[PointField] = [
        PointField(0, VectorValue.dense[DType.float32]([1, 2, 3])),
        PointField(1, VectorValue.sparse([])),
    ]
    for field_id in range(2, 1024):
        specs.append(VectorFieldSpec(field_id, String(field_id), 0, 0, 0, 0, 1))
        fields.append(
            PointField(
                field_id, VectorValue.dense[DType.float32]([Float32(field_id)])
            )
        )
    var catalog = FieldCatalog(1, 0, specs^)
    var point = PointState.live(42, 1, 1, fields^, [])
    var bytes = encode_point_record(point, catalog)
    var decoded = decode_point_record(bytes, catalog)
    assert_equal(decoded.field_count(), 1024)
    assert_equal(
        decoded.field_at(1023).value().dense_values[DType.float32]()[0],
        Float32(1023),
    )
    assert_equal(encode_point_record(decoded, catalog), bytes)
    _u32(bytes, 32, 1025)
    with assert_raises():
        _ = decode_point_record(bytes, catalog)
    var legacy = decode_field_catalog_bytes(
        read_file_bytes("tests/fixtures/field-catalog/legacy-v1.bin")
    )
    with assert_raises():
        _ = decode_point_record(_fixture("default-and-named.bin"), legacy)
    with assert_raises():
        _ = decode_point_record(_fixture("type-matrix.bin"), source)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
