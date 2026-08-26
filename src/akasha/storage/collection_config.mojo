from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.storage.checksum import BinaryReader, BinaryWriter, crc32_range
from akasha.storage.filesystem import (
    atomic_replace,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    sync_directory,
    write_file_sync,
)


comptime _MAGIC_0 = UInt8(0x41)  # A
comptime _MAGIC_1 = UInt8(0x4B)  # K
comptime _MAGIC_2 = UInt8(0x43)  # C
comptime _MAGIC_3 = UInt8(0x46)  # F
comptime _VERSION = UInt16(1)
comptime _ENCODED_SIZE = 60
comptime _CHECKSUM_OFFSET = 56
comptime _CONFIG_NAME = "collection.bin"
comptime _TEMP_NAME = "collection.bin.tmp"


def encode_collection_config(
    config: CollectionConfig,
) raises -> List[UInt8]:
    """Encode a validated collection identity as fixed-width v1 bytes."""
    config.validate()

    var writer = BinaryWriter()
    writer.write_u8(_MAGIC_0)
    writer.write_u8(_MAGIC_1)
    writer.write_u8(_MAGIC_2)
    writer.write_u8(_MAGIC_3)
    writer.write_u16(_VERSION)
    writer.write_u16(0)  # Flags.
    writer.write_u32(UInt32(config.dimension))
    writer.write_u8(config.ann_metric.tag())
    writer.write_u8(config.scalar_kind.tag())
    writer.write_u16(UInt16(config.m))
    writer.write_u16(UInt16(config.m0))
    writer.write_u16(0)  # Reserved alignment bytes.
    writer.write_u32(UInt32(config.ef_construction))
    writer.write_u32(UInt32(config.default_ef_search))
    writer.write_u32(UInt32(config.max_ef_search))
    writer.write_u16(UInt16(config.max_level))
    writer.write_u8(UInt8(config.rebuild_inactive_percent))
    writer.write_u8(0)  # Reserved alignment byte.
    writer.write_u32(UInt32(config.delta_max_points))
    writer.write_u64(config.level_seed)
    writer.write_u64(0)  # Reserved for a future compatible extension.

    var body = writer.take_bytes()
    if len(body) != _CHECKSUM_OFFSET:
        raise Error("collection config encoder size mismatch")
    var checksum = crc32_range(body, 4, _CHECKSUM_OFFSET)
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def decode_collection_config_bytes(
    var bytes: List[UInt8],
) raises -> CollectionConfig:
    """Decode and validate one exact fixed-width v1 collection config."""
    if len(bytes) != _ENCODED_SIZE:
        raise Error("collection config length mismatch")

    var stored_checksum = _read_u32_at(bytes, _CHECKSUM_OFFSET)
    if crc32_range(bytes, 4, _CHECKSUM_OFFSET) != stored_checksum:
        raise Error("collection config checksum mismatch")

    var reader = BinaryReader(bytes^)
    if (
        reader.read_u8() != _MAGIC_0
        or reader.read_u8() != _MAGIC_1
        or reader.read_u8() != _MAGIC_2
        or reader.read_u8() != _MAGIC_3
    ):
        raise Error("invalid collection config magic")
    if reader.read_u16() != _VERSION:
        raise Error("unsupported collection config version")
    if reader.read_u16() != 0:
        raise Error("unsupported collection config flags")

    var dimension = Int(reader.read_u32())
    var metric = MetricKind.from_tag(reader.read_u8())
    var scalar = ScalarKind.from_tag(reader.read_u8())
    var m = Int(reader.read_u16())
    var m0 = Int(reader.read_u16())
    if reader.read_u16() != 0:
        raise Error("nonzero collection config reserved bytes")
    var ef_construction = Int(reader.read_u32())
    var default_ef_search = Int(reader.read_u32())
    var max_ef_search = Int(reader.read_u32())
    var max_level = Int(reader.read_u16())
    var rebuild_inactive_percent = Int(reader.read_u8())
    if reader.read_u8() != 0:
        raise Error("nonzero collection config reserved byte")
    var delta_max_points = Int(reader.read_u32())
    var level_seed = reader.read_u64()
    if reader.read_u64() != 0:
        raise Error("nonzero collection config reserved extension bytes")
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected collection config payload")

    var config = CollectionConfig(
        dimension=dimension,
        ann_metric=metric,
        scalar_kind=scalar,
        m=m,
        m0=m0,
        ef_construction=ef_construction,
        default_ef_search=default_ef_search,
        max_ef_search=max_ef_search,
        max_level=max_level,
        rebuild_inactive_percent=rebuild_inactive_percent,
        delta_max_points=delta_max_points,
        level_seed=level_seed,
    )
    config.validate()
    return config^


def publish_collection_config(
    directory: String, config: CollectionConfig
) raises:
    """Durably publish a collection config without replacing an identity."""
    config.validate()
    var temporary_path = directory + "/" + _TEMP_NAME
    var final_path = directory + "/" + _CONFIG_NAME

    # A stale temp file is never authoritative and is safe to discard.
    remove_file_if_exists(temporary_path)
    if path_exists(final_path):
        var existing = load_collection_config(directory)
        if existing != config:
            raise Error("collection configuration does not match existing file")
        return

    var bytes = encode_collection_config(config)
    try:
        write_file_sync(temporary_path, bytes)
        atomic_replace(temporary_path, final_path)
        sync_directory(directory)
    except error:
        remove_file_if_exists(temporary_path)
        raise Error(String(error))


def load_collection_config(directory: String) raises -> CollectionConfig:
    """Load and validate exactly ``collection.bin`` from a collection."""
    var bytes = read_file_bytes(directory + "/" + _CONFIG_NAME)
    return decode_collection_config_bytes(bytes^)


def collection_config_exists(directory: String) -> Bool:
    return path_exists(directory + "/" + _CONFIG_NAME)


def _read_u32_at(bytes: List[UInt8], offset: Int) -> UInt32:
    return (
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )
