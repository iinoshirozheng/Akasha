from akasha.storage.checksum import (
    BinaryReader,
    BinaryWriter,
    crc32_range,
)
from akasha.storage.filesystem import (
    atomic_replace,
    path_exists,
    read_file_bytes,
    sync_directory,
    write_file_sync,
)


comptime _MAGIC_0 = UInt8(0x41)  # A
comptime _MAGIC_1 = UInt8(0x4B)  # K
comptime _MAGIC_2 = UInt8(0x4D)  # M
comptime _MAGIC_3 = UInt8(0x46)  # F
comptime _VERSION = UInt16(1)
comptime _FIXED_SIZE = 32
comptime _MANIFEST_NAME = "manifest.bin"
comptime _TEMP_NAME = "manifest.bin.tmp"


struct Manifest(Movable):
    """The atomic pointer to one committed snapshot segment."""

    var dimension: Int
    var last_sequence: UInt64
    var segment_checksum: UInt32
    var segment_name: String

    def __init__(
        out self,
        dimension: Int,
        last_sequence: UInt64,
        segment_checksum: UInt32,
        segment_name: String,
    ):
        self.dimension = dimension
        self.last_sequence = last_sequence
        self.segment_checksum = segment_checksum
        self.segment_name = String(copy=segment_name)


def encode_manifest(
    dimension: Int,
    last_sequence: UInt64,
    segment_checksum: UInt32,
    segment_name: String,
) raises -> List[UInt8]:
    _validate_segment_name(segment_name)
    if dimension <= 0:
        raise Error("manifest dimension must be positive")
    var name_length = segment_name.byte_length()
    if name_length > Int(UInt16.MAX):
        raise Error("manifest segment name is too long")

    var writer = BinaryWriter()
    writer.write_u8(_MAGIC_0)
    writer.write_u8(_MAGIC_1)
    writer.write_u8(_MAGIC_2)
    writer.write_u8(_MAGIC_3)
    writer.write_u16(_VERSION)
    writer.write_u16(0)
    writer.write_u32(UInt32(dimension))
    writer.write_u64(last_sequence)
    writer.write_u32(segment_checksum)
    writer.write_u16(UInt16(name_length))
    writer.write_u16(0)
    for byte in segment_name.bytes():
        writer.write_u8(byte)

    var body = writer.take_bytes()
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def decode_manifest_bytes(
    var bytes: List[UInt8], expected_dimension: Int
) raises -> Manifest:
    if expected_dimension <= 0:
        raise Error("manifest dimension must be positive")
    if len(bytes) < _FIXED_SIZE:
        raise Error("truncated manifest")

    var encoded_size = len(bytes)
    var stored_checksum = UInt32(_read_u32_at(bytes, encoded_size - 4))
    if crc32_range(bytes, 4, encoded_size - 4) != stored_checksum:
        raise Error("manifest checksum mismatch")

    var reader = BinaryReader(bytes^)
    if (
        reader.read_u8() != _MAGIC_0
        or reader.read_u8() != _MAGIC_1
        or reader.read_u8() != _MAGIC_2
        or reader.read_u8() != _MAGIC_3
    ):
        raise Error("invalid manifest magic")
    if reader.read_u16() != _VERSION:
        raise Error("unsupported manifest version")
    if reader.read_u16() != 0:
        raise Error("unsupported manifest flags")
    var dimension = Int(reader.read_u32())
    if dimension != expected_dimension:
        raise Error("manifest dimension mismatch")
    var last_sequence = reader.read_u64()
    var segment_checksum = reader.read_u32()
    var name_length = Int(reader.read_u16())
    if reader.read_u16() != 0:
        raise Error("unsupported manifest reserved field")
    if _FIXED_SIZE + name_length != encoded_size:
        raise Error("manifest length mismatch")
    var name_bytes = reader.read_bytes(name_length)
    var segment_name = String(from_utf8=name_bytes)
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected manifest payload")
    _validate_segment_name(segment_name)
    return Manifest(dimension, last_sequence, segment_checksum, segment_name)


def publish_manifest(directory: String, manifest: Manifest) raises:
    var bytes = encode_manifest(
        manifest.dimension,
        manifest.last_sequence,
        manifest.segment_checksum,
        manifest.segment_name,
    )
    var temporary_path = directory + "/" + _TEMP_NAME
    var final_path = directory + "/" + _MANIFEST_NAME
    write_file_sync(temporary_path, bytes)
    atomic_replace(temporary_path, final_path)
    sync_directory(directory)


def load_manifest(
    directory: String, expected_dimension: Int
) raises -> Manifest:
    var bytes = read_file_bytes(directory + "/" + _MANIFEST_NAME)
    var manifest = decode_manifest_bytes(bytes^, expected_dimension)
    if not path_exists(directory + "/" + manifest.segment_name):
        raise Error("manifest references a missing segment")
    return manifest^


def _validate_segment_name(segment_name: String) raises:
    if segment_name.byte_length() == 0:
        raise Error("manifest segment name cannot be empty")
    for byte in segment_name.bytes():
        if byte == UInt8(0) or byte == UInt8(0x2F):
            raise Error("manifest segment name must be a file name")


def _read_u32_at(bytes: List[UInt8], offset: Int) -> Int:
    return Int(
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )
