from akasha.common.config import CollectionConfig
from akasha.document.vector_schema import (
    FieldCatalog,
    VectorFieldSpec,
    legacy_vector_fields,
)
from akasha.storage.checksum import crc32_range
from akasha.storage.collection_config import decode_collection_config_bytes
from akasha.storage.field_catalog import (
    decode_field_catalog_bytes,
    encode_field_catalog,
    load_field_catalog,
)
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_false, assert_raises, TestSuite


def _fixture(name: String = "named-f32-v2.bin") raises -> List[UInt8]:
    return read_file_bytes("tests/fixtures/field-catalog/" + name)


def _rechecksum(mut bytes: List[UInt8]):
    var crc = crc32_range(bytes, 4, len(bytes) - 4)
    for i in range(4):
        bytes[len(bytes) - 4 + i] = UInt8(crc >> UInt32(i * 8))


def _set_u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for i in range(4):
        bytes[offset + i] = UInt8(value >> UInt32(i * 8))


def test_named_catalog_decodes_independent_bytes_and_stable_noncontiguous_ids() raises:
    var bytes = _fixture()
    var catalog = decode_field_catalog_bytes(bytes)
    assert_equal(catalog.format_version, 2)
    assert_equal(catalog.schema_revision, UInt64(1))
    assert_equal(catalog.legacy_cutover_sequence, UInt64(7))
    assert_equal(catalog.field_count(), 5)
    assert_equal(catalog.field_at(0).scalar, UInt8(0))
    assert_equal(catalog.field_at(0).hnsw.value().scalar_kind.tag(), UInt8(2))
    assert_equal(catalog.field_at(2).name, "image")
    assert_equal(catalog.field_at(2).dimension, 2)
    assert_equal(catalog.field_at(2).metric, UInt8(2))
    assert_equal(catalog.field_at(2).hnsw.value().scalar_kind.tag(), UInt8(1))
    assert_equal(catalog.named_ordinal("text"), 3)
    assert_equal(catalog.ordinal_for(7), 3)
    assert_equal(catalog.ordinal_for(3), -1)
    assert_equal(catalog.ordinal_for(-1), -1)
    assert_equal(catalog.named_ordinal("詞"), 4)
    assert_equal(catalog.named_ordinal("missing"), -1)
    assert_false(Bool(catalog.field_at(3).hnsw))
    assert_equal(encode_field_catalog(catalog), bytes)
    with assert_raises():
        _ = catalog.named_ordinal("")
    with assert_raises():
        _ = catalog.field_at(-1)
    with assert_raises():
        _ = catalog.field_at(5)


def test_legacy_mapping_preserves_original_bytes_and_old_reader_rejects_v2() raises:
    var bytes = _fixture("legacy-v1.bin")
    var old = decode_collection_config_bytes(bytes.copy())
    var catalog = decode_field_catalog_bytes(bytes)
    assert_equal(catalog.format_version, 1)
    assert_equal(catalog.schema_revision, UInt64(0))
    assert_equal(catalog.legacy_cutover_sequence, UInt64(0))
    assert_equal(catalog.field_count(), 2)
    assert_equal(catalog.field_at(0).hnsw.value(), old)
    assert_equal(catalog.field_at(0).scalar, UInt8(0))
    assert_equal(catalog.field_at(1).kind, UInt8(1))
    assert_equal(catalog.field_at(1).dimension, 0)
    assert_equal(catalog.field_at(1).index, UInt8(2))
    assert_equal(encode_field_catalog(catalog), bytes)
    with assert_raises():
        _ = decode_collection_config_bytes(_fixture())


def test_type_metadata_fixture_does_not_confuse_authority_with_graph_encoding() raises:
    var bytes = _fixture("type-matrix-v2.bin")
    var catalog = decode_field_catalog_bytes(bytes)
    assert_equal(catalog.field_count(), 9)
    assert_equal(catalog.legacy_cutover_sequence, UInt64(0))
    assert_equal(catalog.field_at(2).scalar, UInt8(2))
    assert_equal(catalog.field_at(3).scalar, UInt8(1))
    assert_equal(catalog.field_at(4).scalar, UInt8(3))
    assert_equal(catalog.field_at(5).scalar, UInt8(4))
    assert_equal(catalog.field_at(6).kind, UInt8(3))
    assert_equal(catalog.field_at(6).dimension, 9)
    assert_equal(catalog.field_at(7).metric, UInt8(4))
    assert_equal(catalog.field_at(8).kind, UInt8(2))
    assert_equal(encode_field_catalog(catalog), bytes)


def test_catalog_rejects_every_truncation_byte_flip_and_trailing_data() raises:
    for name in ["legacy-v1.bin", "named-f32-v2.bin", "type-matrix-v2.bin"]:
        var original = _fixture(name)
        for count in range(len(original)):
            var prefix = List[UInt8]()
            prefix.extend(Span(original)[:count])
            with assert_raises():
                _ = decode_field_catalog_bytes(prefix)
        for offset in range(len(original)):
            var changed = original.copy()
            changed[offset] ^= UInt8(1)
            with assert_raises():
                _ = decode_field_catalog_bytes(changed)
        var trailing = original.copy()
        trailing.append(0)
        with assert_raises():
            _ = decode_field_catalog_bytes(trailing)


def test_crc_valid_invalid_header_fields_and_nested_identity_are_rejected() raises:
    # Offsets come from the independent fixture layout, not the encoder.
    for offset in [4, 6, 16, 32, 36, 37, 38, 39, 40, 44, 46, 48, 52, 116]:
        var changed = _fixture()
        changed[offset] ^= UInt8(1)
        _rechecksum(changed)
        with assert_raises():
            _ = decode_field_catalog_bytes(changed)
    for count in [0, 1, 1025, 4_294_967_295]:
        var changed = _fixture()
        _set_u32(changed, 12, UInt32(count))
        _rechecksum(changed)
        with assert_raises():
            _ = decode_field_catalog_bytes(changed)
    for total in [0, 287, 289, 4_294_967_295]:
        var changed = _fixture()
        _set_u32(changed, 8, UInt32(total))
        _rechecksum(changed)
        with assert_raises():
            _ = decode_field_catalog_bytes(changed)
    for invalid_name_byte in [0, 255]:
        var changed = _fixture()
        changed[164] = UInt8(invalid_name_byte)
        _rechecksum(changed)
        with assert_raises():
            _ = decode_field_catalog_bytes(changed)
    var inner_corrupt = _fixture()
    inner_corrupt[64] ^= UInt8(1)
    _rechecksum(inner_corrupt)
    with assert_raises():
        _ = decode_field_catalog_bytes(inner_corrupt)


def test_catalog_model_rejects_duplicate_names_ids_and_schema_mismatches() raises:
    for duplicate_id in [False, True]:
        var fields = legacy_vector_fields(CollectionConfig.defaults(3))
        fields.append(VectorFieldSpec(2, "image", 0, 0, 1, 0, 2))
        fields.append(
            VectorFieldSpec(2 if duplicate_id else 3, "image", 0, 0, 1, 0, 2)
        )
        with assert_raises():
            _ = FieldCatalog(1, 0, fields^)
    for invalid_name in ["", "x\x00y", "x" * 65536]:
        var fields = legacy_vector_fields(CollectionConfig.defaults(3))
        fields.append(VectorFieldSpec(2, invalid_name, 0, 0, 1, 0, 2))
        with assert_raises():
            _ = FieldCatalog(1, 0, fields^)
    var no_revision = legacy_vector_fields(CollectionConfig.defaults(3))
    with assert_raises():
        _ = FieldCatalog(0, 0, no_revision^)
    var partial_legacy = legacy_vector_fields(CollectionConfig.defaults(3))
    partial_legacy.append(VectorFieldSpec(2, "image", 0, 0, 1, 0, 2))
    with assert_raises():
        _ = FieldCatalog(0, 0, partial_legacy^, format_version=1)


def test_field_model_rejects_invalid_kind_dtype_metric_index_combinations() raises:
    for kind in [0, 1, 2, 3, 255]:
        var bad_scalar = VectorFieldSpec(2, "x", UInt8(kind), 255, 0, 0, 3)
        with assert_raises():
            bad_scalar.validate()
    var cases: List[VectorFieldSpec] = [
        VectorFieldSpec(-1, "x", 0, 0, 0, 0, 3),
        VectorFieldSpec(4_294_967_296, "x", 0, 0, 0, 0, 3),
        VectorFieldSpec(2, "x", 0, 0, 0, 0, 0),
        VectorFieldSpec(2, "x", 0, 0, 0, 0, 4_294_967_296),
        VectorFieldSpec(2, "x", 0, 5, 0, 0, 3),
        VectorFieldSpec(2, "x", 0, 0, 3, 0, 3),
        VectorFieldSpec(2, "x", 0, 0, 0, 2, 3),
        VectorFieldSpec(2, "x", 0, 0, 0, 1, 3),
        VectorFieldSpec(2, "x", 1, 0, 0, 2, 3),
        VectorFieldSpec(2, "x", 1, 1, 0, 2, 0),
        VectorFieldSpec(2, "x", 1, 0, 1, 2, 0),
        VectorFieldSpec(2, "x", 2, 0, 0, 1, 3),
        VectorFieldSpec(2, "x", 3, 0, 3, 0, 9),
        VectorFieldSpec(2, "x", 3, 5, 0, 0, 9),
        VectorFieldSpec(2, "x", 3, 5, 3, 1, 9),
    ]
    for candidate in cases:
        with assert_raises():
            candidate.validate()
    var wrong_config = CollectionConfig.defaults(4)
    var mismatch = VectorFieldSpec(
        2, "x", 0, 0, 1, 1, 3, Optional(wrong_config^)
    )
    with assert_raises():
        mismatch.validate()
    var unused_config = VectorFieldSpec(
        2, "x", 0, 0, 1, 0, 3, Optional(CollectionConfig.defaults(3))
    )
    with assert_raises():
        unused_config.validate()


def test_catalog_owns_decoded_names_and_accepts_inclusive_wire_boundaries() raises:
    var source = _fixture()
    var catalog = decode_field_catalog_bytes(Span(source))
    for ref byte in source:
        byte = 0
    assert_equal(catalog.field_at(2).name, "image")
    assert_equal(catalog.field_at(4).name, "詞")
    var fields = legacy_vector_fields(CollectionConfig.defaults(3))
    fields.append(
        VectorFieldSpec(4_294_967_295, "x" * 65535, 0, 4, 1, 0, 4_294_967_295)
    )
    var boundary = FieldCatalog(UInt64.MAX, UInt64.MAX, fields^)
    var encoded = encode_field_catalog(boundary)
    var round_trip = decode_field_catalog_bytes(encoded)
    assert_equal(round_trip.schema_revision, UInt64.MAX)
    assert_equal(round_trip.legacy_cutover_sequence, UInt64.MAX)
    assert_equal(round_trip.field_at(2).name.byte_length(), 65535)
    assert_equal(round_trip.field_at(2).dimension, 4_294_967_295)


def test_catalog_count_limits_include_default_fields() raises:
    for count in [2, 1024, 1025]:
        var fields = legacy_vector_fields(CollectionConfig.defaults(3))
        for id in range(2, count):
            fields.append(VectorFieldSpec(id, "v" + String(id), 0, 0, 0, 0, 1))
        if count == 1025:
            with assert_raises():
                _ = FieldCatalog(1, 0, fields^)
        else:
            var catalog = FieldCatalog(1, 0, fields^)
            var encoded = encode_field_catalog(catalog)
            var decoded = decode_field_catalog_bytes(encoded)
            assert_equal(decoded.field_count(), count)
            assert_equal(decoded.ordinal_for(count - 1), count - 1)
    var empty = List[VectorFieldSpec]()
    with assert_raises():
        _ = FieldCatalog(1, 0, empty^)


def test_file_reader_ignores_unpublished_identity_and_never_repairs_sources() raises:
    var directory = String(
        "/tmp/akasha-field-catalog-", Int(external_call["getpid", c_int]())
    )
    ensure_directory(directory)
    var temporary: List[UInt8] = [99, 1, 2]
    var torn_wal: List[UInt8] = [65, 75, 87]
    write_file_sync(directory + "/collection.bin.tmp", temporary)
    write_file_sync(directory + "/wal.bin", torn_wal)
    for name in ["legacy-v1.bin", "named-f32-v2.bin"]:
        var bytes = _fixture(name)
        write_file_sync(directory + "/collection.bin", bytes)
        var catalog = load_field_catalog(directory)
        assert_equal(encode_field_catalog(catalog), bytes)
        assert_equal(read_file_bytes(directory + "/collection.bin"), bytes)
        assert_equal(
            read_file_bytes(directory + "/collection.bin.tmp"), temporary
        )
        assert_equal(read_file_bytes(directory + "/wal.bin"), torn_wal)
    remove_file_if_exists(directory + "/collection.bin")
    with assert_raises():
        _ = load_field_catalog(directory)
    assert_equal(read_file_bytes(directory + "/collection.bin.tmp"), temporary)
    remove_file_if_exists(directory + "/collection.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
