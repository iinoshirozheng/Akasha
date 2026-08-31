from akasha.storage.checksum import (
    BinaryReader,
    BinaryWriter,
    crc32_range,
)
from akasha.storage.filesystem import (
    atomic_replace,
    path_exists,
    read_file_bytes_bounded,
    sync_directory,
    write_file_sync,
)


comptime _MAGIC_0 = UInt8(0x41)  # A
comptime _MAGIC_1 = UInt8(0x4B)  # K
comptime _MAGIC_2 = UInt8(0x4D)  # M
comptime _MAGIC_3 = UInt8(0x46)  # F
comptime _VERSION_V1 = UInt16(1)
comptime _VERSION_V2 = UInt16(2)
comptime _VERSION_V3 = UInt16(3)
comptime _FIXED_SIZE_V1 = 32
comptime _FIXED_SIZE_V2 = 40
comptime _FIXED_SIZE_V3 = 40
comptime _HNSW_DESCRIPTOR_FIXED_SIZE = 24
comptime _V3_FLAG_HNSW = UInt16(1)
comptime _MAX_SEGMENTS = 1024
comptime _MAX_LEVEL = 7
comptime _MAX_NAME_BYTES = Int(UInt16.MAX)
# Header + 1024 maximally-sized dense/sparse descriptors + optional HNSW + CRC.
comptime _MAX_MANIFEST_BYTES = (
    36
    + _MAX_SEGMENTS * (28 + _MAX_NAME_BYTES + 8 + _MAX_NAME_BYTES)
    + _HNSW_DESCRIPTOR_FIXED_SIZE
    + _MAX_NAME_BYTES
    + 4
)
comptime _MANIFEST_NAME = "manifest.bin"
comptime _TEMP_NAME = "manifest.bin.tmp"


struct SegmentDescriptor(Movable):
    """One immutable segment referenced by a committed manifest."""

    var level: Int
    var min_sequence: UInt64
    var max_sequence: UInt64
    var checksum: UInt32
    var name: String
    var sparse_checksum: UInt32
    var sparse_name: String

    def __init__(
        out self,
        level: Int,
        min_sequence: UInt64,
        max_sequence: UInt64,
        checksum: UInt32,
        name: String,
        strict_name: Bool = True,
    ) raises:
        if level < 0 or level > _MAX_LEVEL:
            raise Error("manifest segment level is out of bounds")
        if min_sequence > max_sequence:
            raise Error("manifest segment sequence range is invalid")
        _validate_safe_filename(name, strict_name)
        self.level = level
        self.min_sequence = min_sequence
        self.max_sequence = max_sequence
        self.checksum = checksum
        self.name = String(copy=name)
        self.sparse_checksum = 0
        self.sparse_name = String()

    @staticmethod
    def with_sparse(
        level: Int,
        min_sequence: UInt64,
        max_sequence: UInt64,
        checksum: UInt32,
        name: String,
        sparse_checksum: UInt32,
        sparse_name: String,
        strict_name: Bool = True,
    ) raises -> SegmentDescriptor:
        _validate_safe_filename(sparse_name, strict_name)
        var descriptor = SegmentDescriptor(
            level, min_sequence, max_sequence, checksum, name, strict_name
        )
        descriptor.sparse_checksum = sparse_checksum
        descriptor.sparse_name = String(copy=sparse_name)
        return descriptor^

    def clone(self) raises -> SegmentDescriptor:
        if self.sparse_name.byte_length() > 0:
            return SegmentDescriptor.with_sparse(
                self.level,
                self.min_sequence,
                self.max_sequence,
                self.checksum,
                self.name,
                self.sparse_checksum,
                self.sparse_name,
            )
        return SegmentDescriptor(
            self.level,
            self.min_sequence,
            self.max_sequence,
            self.checksum,
            self.name,
        )


struct Manifest(Movable):
    """The atomic pointer to one committed immutable segment generation."""

    var dimension: Int
    var generation: UInt64
    var last_sequence: UInt64
    var segment_checksum: UInt32
    var segment_name: String
    var format_version: Int
    var segments: List[SegmentDescriptor]
    var hnsw_name: Optional[String]
    var hnsw_checksum: Optional[UInt32]
    var hnsw_config_fingerprint: Optional[UInt64]
    var hnsw_point_count: Optional[UInt64]

    def __init__(
        out self,
        dimension: Int,
        last_sequence: UInt64,
        segment_checksum: UInt32,
        segment_name: String,
        strict_name: Bool = True,
    ) raises:
        if dimension <= 0:
            raise Error("manifest dimension must be positive")
        var descriptor = SegmentDescriptor(
            1,
            0,
            last_sequence,
            segment_checksum,
            segment_name,
            strict_name,
        )
        self.dimension = dimension
        self.generation = 0
        self.last_sequence = last_sequence
        self.segment_checksum = segment_checksum
        self.segment_name = String(copy=segment_name)
        self.format_version = 1
        self.segments = List[SegmentDescriptor]()
        self.segments.append(descriptor^)
        self.hnsw_name = Optional[String]()
        self.hnsw_checksum = Optional[UInt32]()
        self.hnsw_config_fingerprint = Optional[UInt64]()
        self.hnsw_point_count = Optional[UInt64]()

    @staticmethod
    def with_segments(
        dimension: Int,
        generation: UInt64,
        last_sequence: UInt64,
        var segments: List[SegmentDescriptor],
        strict_names: Bool = True,
    ) raises -> Manifest:
        if dimension <= 0:
            raise Error("manifest dimension must be positive")
        if generation == 0:
            raise Error("manifest generation must be positive")
        _validate_manifest_segments(last_sequence, segments, strict_names)
        var newest = len(segments) - 1
        var manifest = Manifest(
            dimension,
            last_sequence,
            segments[newest].checksum,
            segments[newest].name,
            strict_names,
        )
        manifest.generation = generation
        manifest.format_version = 2
        manifest.segments = segments^
        return manifest^

    @staticmethod
    def with_hnsw(
        dimension: Int,
        generation: UInt64,
        last_sequence: UInt64,
        var segments: List[SegmentDescriptor],
        hnsw_name: String,
        hnsw_checksum: UInt32,
        hnsw_config_fingerprint: UInt64,
        hnsw_point_count: UInt64,
    ) raises -> Manifest:
        _validate_safe_filename(hnsw_name)
        var manifest = Manifest.with_segments(
            dimension, generation, last_sequence, segments^
        )
        manifest.format_version = 3
        manifest.hnsw_name = Optional(String(copy=hnsw_name))
        manifest.hnsw_checksum = Optional(hnsw_checksum)
        manifest.hnsw_config_fingerprint = Optional(hnsw_config_fingerprint)
        manifest.hnsw_point_count = Optional(hnsw_point_count)
        _ = _validate_hnsw_reference(manifest)
        return manifest^


def encode_manifest(
    dimension: Int,
    last_sequence: UInt64,
    segment_checksum: UInt32,
    segment_name: String,
) raises -> List[UInt8]:
    """Encode the legacy single-segment manifest format."""
    _validate_safe_filename(segment_name, False)
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
    writer.write_u16(_VERSION_V1)
    writer.write_u16(0)
    writer.write_u32(UInt32(dimension))
    writer.write_u64(last_sequence)
    writer.write_u32(segment_checksum)
    writer.write_u16(UInt16(name_length))
    writer.write_u16(0)
    for byte in segment_name.bytes():
        writer.write_u8(byte)
    return _finish_manifest(writer^)


def encode_manifest_v2(manifest: Manifest) raises -> List[UInt8]:
    if _validate_hnsw_reference(manifest):
        raise Error("manifest v2 cannot reference an HNSW sidecar")
    return _encode_multi_manifest(manifest, _VERSION_V2, False, False)


def encode_manifest_v3(manifest: Manifest) raises -> List[UInt8]:
    var has_hnsw = _validate_hnsw_reference(manifest)
    return _encode_multi_manifest(manifest, _VERSION_V3, has_hnsw, True)


def _encode_multi_manifest(
    manifest: Manifest,
    version: UInt16,
    has_hnsw: Bool,
    strict_names: Bool,
) raises -> List[UInt8]:
    if manifest.dimension <= 0:
        raise Error("manifest dimension must be positive")
    if manifest.generation == 0:
        raise Error("manifest generation must be positive")
    _validate_manifest_segments(
        manifest.last_sequence, manifest.segments, strict_names
    )

    var writer = BinaryWriter()
    writer.write_u8(_MAGIC_0)
    writer.write_u8(_MAGIC_1)
    writer.write_u8(_MAGIC_2)
    writer.write_u8(_MAGIC_3)
    writer.write_u16(version)
    writer.write_u16(_V3_FLAG_HNSW if has_hnsw else UInt16(0))
    writer.write_u32(UInt32(manifest.dimension))
    writer.write_u64(manifest.generation)
    writer.write_u64(manifest.last_sequence)
    writer.write_u32(UInt32(len(manifest.segments)))
    writer.write_u32(0)
    for index in range(len(manifest.segments)):
        var name_length = manifest.segments[index].name.byte_length()
        var sparse_name_length = manifest.segments[
            index
        ].sparse_name.byte_length()
        if name_length > Int(UInt16.MAX):
            raise Error("manifest segment name is too long")
        if sparse_name_length > Int(UInt16.MAX):
            raise Error("manifest sparse segment name is too long")
        writer.write_u16(UInt16(manifest.segments[index].level))
        writer.write_u16(UInt16(1 if sparse_name_length > 0 else 0))
        writer.write_u64(manifest.segments[index].min_sequence)
        writer.write_u64(manifest.segments[index].max_sequence)
        writer.write_u32(manifest.segments[index].checksum)
        writer.write_u16(UInt16(name_length))
        writer.write_u16(0)
        for byte in manifest.segments[index].name.bytes():
            writer.write_u8(byte)
        if sparse_name_length > 0:
            writer.write_u32(manifest.segments[index].sparse_checksum)
            writer.write_u16(UInt16(sparse_name_length))
            writer.write_u16(0)
            for byte in manifest.segments[index].sparse_name.bytes():
                writer.write_u8(byte)
    if has_hnsw:
        var hnsw_name = manifest.hnsw_name.value()
        var hnsw_name_length = hnsw_name.byte_length()
        if hnsw_name_length > Int(UInt16.MAX):
            raise Error("manifest HNSW sidecar name is too long")
        writer.write_u32(manifest.hnsw_checksum.value())
        writer.write_u16(UInt16(hnsw_name_length))
        writer.write_u16(UInt16(0))
        writer.write_u64(manifest.hnsw_config_fingerprint.value())
        writer.write_u64(manifest.hnsw_point_count.value())
        for byte in hnsw_name.bytes():
            writer.write_u8(byte)
    return _finish_manifest(writer^)


def decode_manifest_bytes(
    var bytes: List[UInt8], expected_dimension: Int
) raises -> Manifest:
    if expected_dimension <= 0:
        raise Error("manifest dimension must be positive")
    if len(bytes) < 12:
        raise Error("truncated manifest")
    if (
        bytes[0] != _MAGIC_0
        or bytes[1] != _MAGIC_1
        or bytes[2] != _MAGIC_2
        or bytes[3] != _MAGIC_3
    ):
        raise Error("invalid manifest magic")

    var version = _read_u16_at(bytes, 4)
    var minimum_size: Int
    if version == _VERSION_V1:
        minimum_size = _FIXED_SIZE_V1
    elif version == _VERSION_V2:
        minimum_size = _FIXED_SIZE_V2
    elif version == _VERSION_V3:
        minimum_size = _FIXED_SIZE_V3
    else:
        raise Error("unsupported manifest version")
    if len(bytes) < minimum_size:
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
    if reader.read_u16() != version:
        raise Error("manifest version changed during decode")
    var flags = reader.read_u16()
    if version != _VERSION_V3 and flags != UInt16(0):
        raise Error("unsupported manifest flags")
    if version == _VERSION_V3 and flags > _V3_FLAG_HNSW:
        raise Error("unsupported manifest flags")
    var dimension = Int(reader.read_u32())
    if dimension != expected_dimension:
        raise Error("manifest dimension mismatch")

    if version == _VERSION_V1:
        return _decode_manifest_v1(reader^, dimension, encoded_size)
    return _decode_manifest_multi(
        reader^,
        dimension,
        encoded_size,
        version,
        flags == _V3_FLAG_HNSW,
    )


def publish_manifest(directory: String, manifest: Manifest) raises:
    _validate_manifest_names(manifest, True)
    var bytes: List[UInt8]
    if _validate_hnsw_reference(manifest):
        bytes = encode_manifest_v3(manifest)
    elif manifest.format_version == 1:
        bytes = encode_manifest(
            manifest.dimension,
            manifest.last_sequence,
            manifest.segment_checksum,
            manifest.segment_name,
        )
    elif manifest.format_version == 2 or manifest.format_version == 3:
        bytes = encode_manifest_v2(manifest)
    else:
        raise Error("unsupported in-memory manifest version")
    var temporary_path = directory + "/" + _TEMP_NAME
    var final_path = directory + "/" + _MANIFEST_NAME
    write_file_sync(temporary_path, bytes)
    atomic_replace(temporary_path, final_path)
    sync_directory(directory)


def load_manifest(
    directory: String, expected_dimension: Int
) raises -> Manifest:
    var bytes = read_file_bytes_bounded(
        directory + "/" + _MANIFEST_NAME, _MAX_MANIFEST_BYTES
    )
    var manifest = decode_manifest_bytes(bytes^, expected_dimension)
    _validate_manifest_names(manifest, True)
    for index in range(len(manifest.segments)):
        if not path_exists(directory + "/" + manifest.segments[index].name):
            raise Error("manifest references a missing segment")
        if manifest.segments[
            index
        ].sparse_name.byte_length() > 0 and not path_exists(
            directory + "/" + manifest.segments[index].sparse_name
        ):
            raise Error("manifest references a missing sparse segment")
    return manifest^


def _decode_manifest_v1(
    var reader: BinaryReader, dimension: Int, encoded_size: Int
) raises -> Manifest:
    var last_sequence = reader.read_u64()
    var segment_checksum = reader.read_u32()
    var name_length = Int(reader.read_u16())
    if reader.read_u16() != 0:
        raise Error("unsupported manifest reserved field")
    if _FIXED_SIZE_V1 + name_length != encoded_size:
        raise Error("manifest length mismatch")
    var name_bytes = reader.read_bytes(name_length)
    var segment_name = String(from_utf8=name_bytes)
    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected manifest payload")
    return Manifest(
        dimension, last_sequence, segment_checksum, segment_name, False
    )


def _decode_manifest_multi(
    var reader: BinaryReader,
    dimension: Int,
    encoded_size: Int,
    version: UInt16,
    has_hnsw: Bool,
) raises -> Manifest:
    var strict_names = version == _VERSION_V3
    var generation = reader.read_u64()
    var last_sequence = reader.read_u64()
    var segment_count_u32 = reader.read_u32()
    if segment_count_u32 == 0 or segment_count_u32 > UInt32(_MAX_SEGMENTS):
        raise Error("manifest segment count is out of bounds")
    var segment_count = Int(segment_count_u32)
    if reader.read_u32() != 0:
        raise Error("unsupported manifest reserved field")
    var extension_size = _HNSW_DESCRIPTOR_FIXED_SIZE if has_hnsw else 0
    if encoded_size < _FIXED_SIZE_V2 + extension_size:
        raise Error("truncated manifest")
    if segment_count > (encoded_size - _FIXED_SIZE_V2 - extension_size) // 28:
        raise Error("manifest segment count exceeds file length")

    var segments = List[SegmentDescriptor](capacity=segment_count)
    for _ in range(segment_count):
        var level = Int(reader.read_u16())
        var descriptor_flags = reader.read_u16()
        if descriptor_flags > 1:
            raise Error("unsupported manifest segment flags")
        var min_sequence = reader.read_u64()
        var max_sequence = reader.read_u64()
        var checksum = reader.read_u32()
        var name_length = Int(reader.read_u16())
        if reader.read_u16() != 0:
            raise Error("unsupported manifest segment reserved field")
        var name_bytes = reader.read_bytes(name_length)
        var name = String(from_utf8=name_bytes)
        if descriptor_flags == 1:
            var sparse_checksum = reader.read_u32()
            var sparse_name_length = Int(reader.read_u16())
            if reader.read_u16() != 0:
                raise Error("unsupported manifest sparse reserved field")
            var sparse_name_bytes = reader.read_bytes(sparse_name_length)
            var sparse_name = String(from_utf8=sparse_name_bytes)
            segments.append(
                SegmentDescriptor.with_sparse(
                    level,
                    min_sequence,
                    max_sequence,
                    checksum,
                    name,
                    sparse_checksum,
                    sparse_name,
                    strict_names,
                )
            )
        else:
            segments.append(
                SegmentDescriptor(
                    level,
                    min_sequence,
                    max_sequence,
                    checksum,
                    name,
                    strict_names,
                )
            )

    var hnsw_name = Optional[String]()
    var hnsw_checksum = Optional[UInt32]()
    var hnsw_config_fingerprint = Optional[UInt64]()
    var hnsw_point_count = Optional[UInt64]()
    if has_hnsw:
        if reader.remaining() < _HNSW_DESCRIPTOR_FIXED_SIZE + 4:
            raise Error("truncated manifest HNSW reference")
        hnsw_checksum = Optional(reader.read_u32())
        var hnsw_name_length = Int(reader.read_u16())
        if reader.read_u16() != UInt16(0):
            raise Error("unsupported manifest HNSW reserved field")
        hnsw_config_fingerprint = Optional(reader.read_u64())
        hnsw_point_count = Optional(reader.read_u64())
        if reader.remaining() != hnsw_name_length + 4:
            raise Error("manifest HNSW reference length mismatch")
        var hnsw_name_bytes = reader.read_bytes(hnsw_name_length)
        hnsw_name = Optional(String(from_utf8=hnsw_name_bytes))

    _ = reader.read_u32()
    if reader.remaining() != 0:
        raise Error("unexpected manifest payload")
    var manifest = Manifest.with_segments(
        dimension, generation, last_sequence, segments^, strict_names
    )
    manifest.format_version = Int(version)
    if has_hnsw:
        _validate_safe_filename(hnsw_name.value())
        manifest.hnsw_name = hnsw_name^
        manifest.hnsw_checksum = hnsw_checksum
        manifest.hnsw_config_fingerprint = hnsw_config_fingerprint
        manifest.hnsw_point_count = hnsw_point_count
        _ = _validate_hnsw_reference(manifest)
    return manifest^


def _validate_manifest_segments(
    last_sequence: UInt64,
    segments: List[SegmentDescriptor],
    strict_names: Bool = True,
) raises:
    if len(segments) == 0 or len(segments) > _MAX_SEGMENTS:
        raise Error("manifest segment count is out of bounds")
    var previous_max = UInt64(0)
    for index in range(len(segments)):
        _validate_safe_filename(segments[index].name, strict_names)
        if segments[index].sparse_name.byte_length() > 0:
            _validate_safe_filename(segments[index].sparse_name, strict_names)
        if segments[index].max_sequence > last_sequence:
            raise Error("manifest segment exceeds checkpoint sequence")
        if index > 0 and segments[index].min_sequence <= previous_max:
            raise Error("manifest segment sequence ranges must increase")
        for prior in range(index):
            if segments[prior].name == segments[index].name:
                raise Error("manifest segment names must be unique")
            if (
                segments[index].sparse_name.byte_length() > 0
                and segments[prior].sparse_name == segments[index].sparse_name
            ):
                raise Error("manifest sparse segment names must be unique")
        if (
            segments[index].sparse_name.byte_length() > 0
            and segments[index].sparse_name == segments[index].name
        ):
            raise Error("dense and sparse segment names must differ")
        previous_max = segments[index].max_sequence
    if segments[len(segments) - 1].max_sequence != last_sequence:
        raise Error("manifest does not cover checkpoint sequence")


def _finish_manifest(var writer: BinaryWriter) -> List[UInt8]:
    var body = writer.take_bytes()
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def _validate_hnsw_reference(manifest: Manifest) raises -> Bool:
    var has_name = Bool(manifest.hnsw_name)
    if (
        has_name != Bool(manifest.hnsw_checksum)
        or has_name != Bool(manifest.hnsw_config_fingerprint)
        or has_name != Bool(manifest.hnsw_point_count)
    ):
        raise Error(
            "manifest HNSW reference fields must be all present or absent"
        )
    if has_name:
        var hnsw_name = manifest.hnsw_name.value()
        _validate_safe_filename(hnsw_name, True)
        if hnsw_name != "hnsw-" + String(manifest.last_sequence) + ".bin":
            raise Error("manifest HNSW name must match checkpoint sequence")
        for index in range(len(manifest.segments)):
            if hnsw_name == manifest.segments[index].name or (
                manifest.segments[index].sparse_name.byte_length() > 0
                and hnsw_name == manifest.segments[index].sparse_name
            ):
                raise Error("manifest HNSW and segment names must differ")
    return has_name


def _validate_manifest_names(manifest: Manifest, strict: Bool) raises:
    _validate_safe_filename(manifest.segment_name, strict)
    for index in range(len(manifest.segments)):
        _validate_safe_filename(manifest.segments[index].name, strict)
        if manifest.segments[index].sparse_name.byte_length() > 0:
            _validate_safe_filename(
                manifest.segments[index].sparse_name, strict
            )
    if Bool(manifest.hnsw_name):
        _validate_safe_filename(manifest.hnsw_name.value(), True)


def _validate_safe_filename(name: String, strict: Bool = True) raises:
    if name.byte_length() == 0:
        raise Error("manifest reference name cannot be empty")
    if strict and (name == "." or name == ".."):
        raise Error("manifest reference name cannot be a directory alias")
    for byte in name.bytes():
        if byte == UInt8(0) or byte == UInt8(0x2F):
            raise Error("manifest reference name must be a safe file name")


def _read_u16_at(bytes: List[UInt8], offset: Int) -> UInt16:
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << UInt16(8))


def _read_u32_at(bytes: List[UInt8], offset: Int) -> Int:
    return Int(
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )
