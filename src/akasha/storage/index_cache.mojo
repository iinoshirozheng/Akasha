from akasha.storage.checksum import (
    BinaryReader,
    BinaryWriter,
    crc32_range,
    crc32_update,
    CRC32_INITIAL,
)
from akasha.document.codec import encode_payload
from akasha.index.metadata import _write_metadata_cache_row
from akasha.storage.memtable import MemTable
from akasha.storage.filesystem import (
    atomic_replace,
    path_exists,
    read_file_bytes_bounded,
    sync_directory,
    write_file_sync,
)
from std.sys.info import is_little_endian


comptime CACHE_HNSW_KIND = UInt8(1)
comptime CACHE_METADATA_KIND = UInt8(2)
comptime CACHE_HNSW_OVERLAY_KIND = UInt8(3)
comptime CACHE_FIELD_HNSW_KIND = UInt8(4)
comptime _VERSION = UInt16(1)
comptime _FIXED_BYTES = 40
comptime _MAX_PAYLOAD_BYTES = 512 * 1024 * 1024


struct CacheArtifact(Movable):
    """One rebuildable derived-index cache envelope."""

    var version: UInt16
    var kind: UInt8
    var dimension: Int
    var generation: UInt64
    var sequence: UInt64
    var source_checksum: UInt32
    var payload: List[UInt8]

    def __init__(
        out self,
        kind: UInt8,
        dimension: Int,
        generation: UInt64,
        sequence: UInt64,
        source_checksum: UInt32,
        var payload: List[UInt8],
    ) raises:
        _validate_header(kind, dimension, len(payload))
        self.version = _VERSION
        self.kind = kind
        self.dimension = dimension
        self.generation = generation
        self.sequence = sequence
        self.source_checksum = source_checksum
        self.payload = payload^

    def take_payload(mut self) -> List[UInt8]:
        var payload = self.payload^
        self.payload = List[UInt8]()
        return payload^


def encode_cache(artifact: CacheArtifact) raises -> List[UInt8]:
    _validate_header(artifact.kind, artifact.dimension, len(artifact.payload))
    var writer = BinaryWriter()
    writer.write_u8(UInt8(0x41))  # A
    writer.write_u8(UInt8(0x4B))  # K
    writer.write_u8(UInt8(0x49))  # I
    writer.write_u8(UInt8(0x43))  # C
    writer.write_u16(_VERSION)
    writer.write_u8(artifact.kind)
    writer.write_u8(UInt8(0))
    writer.write_u32(UInt32(artifact.dimension))
    writer.write_u64(artifact.generation)
    writer.write_u64(artifact.sequence)
    writer.write_u32(artifact.source_checksum)
    writer.write_u32(UInt32(len(artifact.payload)))
    writer.write_bytes(artifact.payload)
    var body = writer.take_bytes()
    var checksum = crc32_range(body, 0, len(body))
    var final_writer = BinaryWriter()
    final_writer.write_bytes(body)
    final_writer.write_u32(checksum)
    return final_writer.take_bytes()


def decode_cache_bytes(var bytes: List[UInt8]) raises -> CacheArtifact:
    if len(bytes) < _FIXED_BYTES:
        raise Error("derived index cache is truncated")
    var stored_offset = len(bytes) - 4
    var stored_reader = BinaryReader(bytes.copy())
    _ = stored_reader.read_bytes(stored_offset)
    var stored_checksum = stored_reader.read_u32()
    var actual_checksum = crc32_range(bytes, 0, stored_offset)
    if stored_checksum != actual_checksum:
        raise Error("derived index cache checksum mismatch")

    var reader = BinaryReader(bytes^)
    if (
        reader.read_u8() != UInt8(0x41)
        or reader.read_u8() != UInt8(0x4B)
        or reader.read_u8() != UInt8(0x49)
        or reader.read_u8() != UInt8(0x43)
    ):
        raise Error("invalid derived index cache magic")
    var version = reader.read_u16()
    if version != _VERSION:
        raise Error("unsupported derived index cache version")
    var kind = reader.read_u8()
    if reader.read_u8() != UInt8(0):
        raise Error("derived index cache reserved byte must be zero")
    var dimension_u32 = reader.read_u32()
    if dimension_u32 > UInt32(Int.MAX):
        raise Error("derived index cache dimension is too large")
    var dimension = Int(dimension_u32)
    var generation = reader.read_u64()
    var sequence = reader.read_u64()
    var source_checksum = reader.read_u32()
    var payload_length_u32 = reader.read_u32()
    if payload_length_u32 > UInt32(_MAX_PAYLOAD_BYTES):
        raise Error("derived index cache payload is too large")
    var payload_length = Int(payload_length_u32)
    if reader.remaining() != payload_length + 4:
        raise Error("derived index cache payload length mismatch")
    var payload = reader.read_bytes(payload_length)
    _ = reader.read_u32()
    _validate_header(kind, dimension, payload_length)
    return CacheArtifact(
        kind,
        dimension,
        generation,
        sequence,
        source_checksum,
        payload^,
    )


def publish_cache(
    directory: String, name: String, artifact: CacheArtifact
) raises:
    _validate_cache_name(name)
    var final_path = directory + "/" + name
    var temporary_path = final_path + ".tmp"
    write_file_sync(temporary_path, encode_cache(artifact))
    atomic_replace(temporary_path, final_path)
    sync_directory(directory)


def load_cache_artifact(path: String) -> Optional[CacheArtifact]:
    """Bound and validate one optional derived artifact before using its key."""
    if not path_exists(path):
        return None
    try:
        return Optional(
            decode_cache_bytes(
                read_file_bytes_bounded(path, _MAX_PAYLOAD_BYTES + _FIXED_BYTES)
            )
        )
    except:
        return None


def load_cache_payload(
    path: String,
    expected_kind: UInt8,
    expected_dimension: Int,
    expected_generation: UInt64,
    expected_sequence: UInt64,
    expected_source_checksum: UInt32,
) -> Optional[List[UInt8]]:
    """Return a current payload; all derived-cache failures are safe misses."""
    var loaded = load_cache_artifact(path)
    if not loaded:
        return None
    var artifact = loaded.take()
    if (
        artifact.kind != expected_kind
        or artifact.dimension != expected_dimension
        or artifact.generation != expected_generation
        or artifact.sequence != expected_sequence
        or artifact.source_checksum != expected_source_checksum
    ):
        return None
    return Optional(artifact.take_payload())


def authoritative_index_checksum(memtable: MemTable) raises -> UInt32:
    """Fingerprint unchanged bytes with at most one row/payload encoded at once."""
    var unused_metadata = BinaryWriter()
    return _encode_authoritative_index[False](memtable, unused_metadata)


def metadata_cache_from_authority(
    memtable: MemTable, generation: UInt64, sequence: UInt64,
) raises -> CacheArtifact:
    """Encode each authority payload once for both CRC and metadata cache.

    The stable authority slots are the source of the metadata ID/live/payload
    layout. This factory neither reads nor mutates a query index or collection.
    """
    var metadata = BinaryWriter()
    var checksum = _encode_authoritative_index[True](memtable, metadata)
    return CacheArtifact(
        CACHE_METADATA_KIND, memtable.dimension, generation, sequence,
        checksum, metadata.take_bytes(),
    )


def _encode_authoritative_index[include_metadata: Bool](
    memtable: MemTable, mut metadata: BinaryWriter,
) raises -> UInt32:
    comptime if include_metadata:
        if memtable.slot_count() > Int(UInt32.MAX):
            raise Error("metadata cache slot count exceeds format")
        metadata.write_u32(UInt32(memtable.slot_count()))
    var writer = BinaryWriter()
    writer.write_u32(UInt32(memtable.dimension))
    writer.write_u32(UInt32(memtable.slot_count()))
    var register = writer.update_crc32_and_clear(CRC32_INITIAL)
    for ordinal in range(memtable.slot_count()):
        ref entry = memtable.entry_ref_at(ordinal)
        writer.write_i64(Int64(entry.id))
        writer.write_u64(entry.sequence)
        writer.write_u8(UInt8(1) if entry.tombstone else UInt8(0))
        writer.write_u8(UInt8(0))
        writer.write_u16(UInt16(0))
        register = writer.update_crc32_and_clear(register)
        comptime if is_little_endian():
            # The immutable row stays borrowed for this synchronous call. Its
            # native F32 representation is exactly the writer's little-endian
            # encoding; neither pointer nor Span escapes.
            ref values = entry.values()
            var bytes = Span(
                unsafe_ptr=values.unsafe_ptr().unsafe_bitcast[UInt8](),
                length=len(values) * 4,
            )
            register = crc32_update(register, bytes)
        else:
            for value in entry.values():
                writer.write_f32(value)
            register = writer.update_crc32_and_clear(register)
        var fields = encode_payload(entry.fields())
        writer.write_u32(UInt32(len(fields)))
        register = writer.update_crc32_and_clear(register)
        register = crc32_update(register, Span(fields))
        comptime if include_metadata:
            _write_metadata_cache_row(
                metadata, entry.id, not entry.tombstone, fields
            )
    return ~register


def _validate_header(kind: UInt8, dimension: Int, payload_length: Int) raises:
    if (
        kind != CACHE_HNSW_KIND
        and kind != CACHE_METADATA_KIND
        and kind != CACHE_HNSW_OVERLAY_KIND
        and kind != CACHE_FIELD_HNSW_KIND
    ):
        raise Error("unknown derived index cache kind")
    if dimension <= 0:
        raise Error("derived index cache dimension must be positive")
    if payload_length < 0 or payload_length > _MAX_PAYLOAD_BYTES:
        raise Error("derived index cache payload is too large")


def _validate_cache_name(name: String) raises:
    if name.byte_length() == 0:
        raise Error("derived index cache name cannot be empty")
    for byte in name.bytes():
        if byte == UInt8(0) or byte == UInt8(0x2F):
            raise Error("derived index cache name is invalid")
