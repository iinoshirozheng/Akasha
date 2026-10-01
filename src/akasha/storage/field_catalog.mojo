from akasha.common.config import CollectionConfig
from akasha.document.vector_schema import (
    FieldCatalog,
    VectorFieldSpec,
    legacy_vector_fields,
    MAX_FIELD_CATALOG_BYTES,
    MAX_VECTOR_FIELDS,
)
from akasha.storage.checksum import (
    BorrowedBinaryReader,
    BinaryWriter,
    crc32_range,
    crc32_update,
    CRC32_INITIAL,
)
from akasha.storage.collection_config import (
    _CollectionConfigPublishOps,
    _FilesystemPublishOps,
    decode_collection_config_bytes,
    encode_collection_config,
)
from akasha.storage.filesystem import path_exists, read_file_bytes_bounded


comptime _MAGIC = UInt32(0x46434B41)  # AKCF, little-endian.


def load_field_catalog(directory: String) raises -> FieldCatalog:
    """Read only the committed identity, with bounded file acquisition."""
    var bytes = read_file_bytes_bounded(
        directory + "/collection.bin", MAX_FIELD_CATALOG_BYTES
    )
    return decode_field_catalog_bytes(bytes)


def decode_field_catalog_bytes(bytes: List[UInt8]) raises -> FieldCatalog:
    """Decode metadata only, without changing collection state or write mode."""
    return decode_field_catalog_bytes(Span(bytes))


def decode_field_catalog_bytes(bytes: Span[UInt8, _]) raises -> FieldCatalog:
    if len(bytes) < 8 or len(bytes) > MAX_FIELD_CATALOG_BYTES:
        raise Error("field catalog length exceeds bounds")
    var reader = BorrowedBinaryReader(bytes)
    if reader.read_u32() != _MAGIC:
        raise Error("invalid field catalog magic")
    var version = reader.read_u16()
    if version == 1:
        if len(bytes) != 60:
            raise Error("legacy collection config length mismatch")
        var config = _decode_hnsw_config(bytes)
        return FieldCatalog(
            0, 0, legacy_vector_fields(config), format_version=1
        )
    if version != 2:
        raise Error("unsupported field catalog version")
    if len(bytes) < 36:
        raise Error("truncated field catalog header")
    if reader.read_u16() != 0:
        raise Error("unsupported field catalog flags")
    if Int(reader.read_u32()) != len(bytes):
        raise Error("field catalog length mismatch")
    var count = Int(reader.read_u32())
    if count < 2 or count > MAX_VECTOR_FIELDS:
        raise Error("vector field count exceeds catalog bounds")
    var revision = reader.read_u64()
    var cutover = reader.read_u64()
    if count * 24 > reader.remaining() - 4:
        raise Error("truncated field catalog descriptors")
    var checksum_reader = BorrowedBinaryReader(bytes[len(bytes) - 4 :])
    var stored_checksum = checksum_reader.read_u32()
    if (
        ~crc32_update(CRC32_INITIAL, bytes[4 : len(bytes) - 4])
        != stored_checksum
    ):
        raise Error("field catalog checksum mismatch")

    var fields = List[VectorFieldSpec](capacity=count)
    for _ in range(count):
        var id = Int(reader.read_u32())
        var kind = reader.read_u8()
        var scalar = reader.read_u8()
        var metric = reader.read_u8()
        var index = reader.read_u8()
        var dimension = Int(reader.read_u32())
        var name_length = Int(reader.read_u16())
        var config_length = Int(reader.read_u16())
        if reader.read_u32() != 0 or reader.read_u32() != 0:
            raise Error("nonzero field descriptor flags or reserved bytes")
        if config_length != (60 if index == 1 else 0):
            raise Error("invalid vector index configuration length")
        var name = String(from_utf8=reader.read_span(name_length))
        var hnsw = Optional[CollectionConfig]()
        if config_length != 0:
            hnsw = Optional(_decode_hnsw_config(reader.read_span(60)))
        fields.append(
            VectorFieldSpec(
                id, name, kind, scalar, metric, index, dimension, hnsw^
            )
        )
    if reader.remaining() != 4:
        raise Error("unexpected trailing field catalog data")
    return FieldCatalog(revision, cutover, fields^)


def encode_field_catalog(catalog: FieldCatalog) raises -> List[UInt8]:
    """Encode validated metadata; this does not publish or migrate a collection.
    """
    catalog.validate()
    if catalog.format_version == 1:
        return encode_collection_config(catalog.field_at(0).hnsw.value())
    var length = 36
    for ordinal in range(catalog.field_count()):
        ref field = catalog.field_at(ordinal)
        length += 24 + field.name.byte_length() + (60 if field.hnsw else 0)
    if length > MAX_FIELD_CATALOG_BYTES:
        raise Error("field catalog length exceeds bounds")
    var writer = BinaryWriter()
    writer.write_u32(_MAGIC)
    writer.write_u16(2)
    writer.write_u16(0)
    writer.write_u32(UInt32(length))
    writer.write_u32(UInt32(catalog.field_count()))
    writer.write_u64(catalog.schema_revision)
    writer.write_u64(catalog.legacy_cutover_sequence)
    for ordinal in range(catalog.field_count()):
        ref field = catalog.field_at(ordinal)
        writer.write_u32(UInt32(field.id))
        writer.write_u8(field.kind)
        writer.write_u8(field.scalar)
        writer.write_u8(field.metric)
        writer.write_u8(field.index)
        writer.write_u32(UInt32(field.dimension))
        writer.write_u16(UInt16(field.name.byte_length()))
        writer.write_u16(UInt16(60 if field.hnsw else 0))
        writer.write_u32(0)
        writer.write_u32(0)
        for byte in field.name.bytes():
            writer.write_u8(byte)
        if field.hnsw:
            var config = encode_collection_config(field.hnsw.value())
            writer.write_bytes(config)
    var body = writer.take_bytes()
    if len(body) != length - 4:
        raise Error("field catalog encoder length mismatch")
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def _decode_hnsw_config(bytes: Span[UInt8, _]) raises -> CollectionConfig:
    # Reuse the exact legacy validator. This bounded 60-byte copy is metadata,
    # not a vector-data decode or a reason to relax the closed v1 contract.
    var owned = List[UInt8](capacity=60)
    owned.extend(bytes)
    return decode_collection_config_bytes(owned^)


def field_catalog_checksum(catalog: FieldCatalog) raises -> UInt32:
    """Return the canonical v2 identity checksum used by durable envelopes."""
    if catalog.format_version != 2:
        raise Error("field-aware envelopes require a v2 catalog")
    var bytes = encode_field_catalog(catalog)
    var reader = BorrowedBinaryReader(Span(bytes)[len(bytes) - 4 :])
    return reader.read_u32()


def publish_field_catalog(
    directory: String,
    catalog: FieldCatalog,
    expected_identity: List[UInt8],
) raises:
    """Publish a preflighted v2 identity while holding the collection lock.

    expected_identity is the exact committed v1 identity observed before full
    recovery preflight, or empty if absent. All legacy authority must already
    have been validated through catalog's cutover before calling this function.
    This only publishes identity; it does not repair WALs or enable writers.
    """
    var ops = _FilesystemPublishOps()
    _publish_field_catalog_with_ops(directory, catalog, expected_identity, ops)


def _publish_field_catalog_with_ops[
    Ops: _CollectionConfigPublishOps
](
    directory: String,
    catalog: FieldCatalog,
    expected_identity: List[UInt8],
    mut ops: Ops,
) raises:
    if catalog.format_version != 2:
        raise Error("field publication requires a v2 catalog")
    var target = encode_field_catalog(catalog)
    if len(expected_identity) != 0:
        var previous = decode_field_catalog_bytes(expected_identity)
        if previous.format_version != 1:
            raise Error("field publication only upgrades legacy identity")
        if (
            previous.field_at(0).hnsw.value()
            != catalog.field_at(0).hnsw.value()
        ):
            raise Error("field migration cannot change default configuration")

    var final_path = directory + "/collection.bin"
    var temporary_path = directory + "/collection.bin.tmp"
    var already_published = False
    if path_exists(final_path):
        var current = read_file_bytes_bounded(
            final_path, MAX_FIELD_CATALOG_BYTES
        )
        already_published = current == target
        if not already_published and current != expected_identity:
            raise Error("collection identity changed since migration preflight")
    elif len(expected_identity) != 0:
        raise Error("collection identity disappeared since migration preflight")

    # Do not disturb even an unrelated temporary file on a rejected transition.
    ops.remove_temp(temporary_path)
    if already_published:
        # Rename may have succeeded before an earlier directory fsync failed.
        # Complete the barrier without replacing an already accepted identity.
        ops.sync_parent(directory)
        return
    try:
        ops.write_temp(temporary_path, target)
        ops.replace_temp(temporary_path, final_path)
        ops.sync_parent(directory)
    except error:
        var original_error = String(error)
        try:
            ops.remove_temp(temporary_path)
        except cleanup_error:
            _ = String(cleanup_error)
        raise Error(original_error)
