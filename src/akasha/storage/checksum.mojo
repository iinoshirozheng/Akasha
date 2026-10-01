from std.sys.info import CompilationTarget, _triple_attr, is_little_endian
from std.sys.intrinsics import llvm_intrinsic
from std.collections import Array
from std.memory import bitcast, unsafe_memcpy


def crc32(data: List[UInt8]) -> UInt32:
    """Compute CRC-32/ISO-HDLC over an owned byte list."""
    return crc32_range(data, 0, len(data))


def crc32_range(data: List[UInt8], start: Int, end: Int) -> UInt32:
    """Compute CRC-32/ISO-HDLC over ``[start, end)``."""
    return ~crc32_update(CRC32_INITIAL, Span(data)[start:end])


comptime CRC32_INITIAL = UInt32(0xFFFFFFFF)
"""The CRC-32/ISO-HDLC register before any byte; see ``crc32_update``."""


@always_inline
def crc32_update(register: UInt32, data: Span[UInt8, _]) -> UInt32:
    """Advance a CRC-32/ISO-HDLC register over ``data``.

    Streams start from ``CRC32_INITIAL``; the checksum is ``~register``.
    """
    # Mojo 1.0 exposes its target feature predicate through this internal
    # stdlib accessor. Gate both the architecture and the actual CRC feature;
    # a CPU model or NEON support alone does not prove CRC availability.
    comptime triple = StaticString(_triple_attr())
    comptime if (
        triple.startswith("aarch64-") or triple.startswith("arm64-")
    ) and is_little_endian() and CompilationTarget._has_feature["crc"]():
        return _crc32_update_arm(register, data)
    if len(data) >= 32:
        return _crc32_update_blocks(register, data)
    return _crc32_update_bytes(register, data)


@always_inline
def _crc32_update_arm(register: UInt32, data: Span[UInt8, _]) -> UInt32:
    """Advance the ISO-HDLC register with AArch64 CRC32 (not CRC32C)."""
    var result = register
    var offset = 0
    while len(data) - offset >= 8:
        # The loop proves all eight bytes are within this borrowed Span.
        # Explicit byte alignment permits sliced buffers without over-reading.
        var word = data.unsafe_ptr().unsafe_offset(offset).unsafe_bitcast[
            UInt64
        ]().unsafe_load[alignment=1]()
        result = llvm_intrinsic[
            "llvm.aarch64.crc32x", UInt32, has_side_effect=False
        ](result, word)
        offset += 8
    for byte in data[offset:]:
        result = llvm_intrinsic[
            "llvm.aarch64.crc32b", UInt32, has_side_effect=False
        ](result, UInt32(byte))
    return result


@always_inline
def _crc32_update_bytes(register: UInt32, data: Span[UInt8, _]) -> UInt32:
    var result = register
    for byte in data:
        result = _crc32_update(result, byte)
    return result


def _crc32_table() -> Array[UInt32, 256]:
    var table = Array[UInt32, 256](fill=0)
    for byte in range(256):
        var remainder = UInt32(byte)
        for _ in range(8):
            remainder = (remainder >> 1) ^ (
                UInt32(0xEDB88320) if remainder & 1 else UInt32(0)
            )
        table[byte] = remainder
    return table^


comptime _CRC32_TABLE = _crc32_table()


def _crc32_block_tables() -> Array[UInt32, 2048]:
    var base = _crc32_table()
    var tables = Array[UInt32, 2048](fill=0)
    for byte in range(256):
        tables[byte] = base[byte]
    for level in range(1, 8):
        for byte in range(256):
            var previous = tables[(level - 1) * 256 + byte]
            tables[level * 256 + byte] = (previous >> 8) ^ base[
                Int(previous & 255)
            ]
    return tables^


comptime _CRC32_BLOCK_TABLES = _crc32_block_tables()


def _crc32_update_blocks(register: UInt32, data: Span[UInt8, _]) -> UInt32:
    """Advance eight input bytes at a time with the same reflected polynomial.

    Byte assembly is independent of alignment and native endianness. Each table
    accounts for the zero-byte advances after its byte's position in the block.
    """
    var tables = materialize[_CRC32_BLOCK_TABLES]()
    var result = register
    var offset = 0
    while len(data) - offset >= 8:
        var low = result
        var high = UInt32(0)
        comptime for byte in range(4):
            low ^= UInt32(data[offset + byte]) << UInt32(byte * 8)
            high |= UInt32(data[offset + byte + 4]) << UInt32(byte * 8)
        result = (
            tables[7 * 256 + Int(low & 255)]
            ^ tables[6 * 256 + Int((low >> 8) & 255)]
            ^ tables[5 * 256 + Int((low >> 16) & 255)]
            ^ tables[4 * 256 + Int(low >> 24)]
            ^ tables[3 * 256 + Int(high & 255)]
            ^ tables[2 * 256 + Int((high >> 8) & 255)]
            ^ tables[256 + Int((high >> 16) & 255)]
            ^ tables[Int(high >> 24)]
        )
        offset += 8
    return _crc32_update_bytes(result, data[offset:])


@always_inline
def _crc32_update(checksum: UInt32, byte: UInt8) -> UInt32:
    """One byte of CRC-32/ISO-HDLC (same polynomial, init and final XOR)."""
    var table = materialize[_CRC32_TABLE]()
    return (checksum >> 8) ^ table[Int((checksum ^ UInt32(byte)) & 0xFF)]


struct BinaryWriter:
    """An owned little-endian byte builder for storage formats."""

    var _bytes: List[UInt8]

    def __init__(out self):
        self._bytes = List[UInt8]()

    def write_u8(mut self, value: UInt8):
        self._bytes.append(value)

    def write_u16(mut self, value: UInt16):
        for shift in range(0, 16, 8):
            self._bytes.append(UInt8(value >> UInt16(shift)))

    def write_u32(mut self, value: UInt32):
        for shift in range(0, 32, 8):
            self._bytes.append(UInt8(value >> UInt32(shift)))

    def write_u64(mut self, value: UInt64):
        for shift in range(0, 64, 8):
            self._bytes.append(UInt8(value >> UInt64(shift)))

    def write_i64(mut self, value: Int64):
        self.write_u64(bitcast[DType.uint64](value))

    def write_f32(mut self, value: Float32):
        self.write_u32(bitcast[DType.uint32](value))

    def write_f32s(mut self, values: List[Float32]):
        """Copy an F32 tape as little-endian bytes without changing any bits."""
        comptime if is_little_endian():
            self._bytes.extend(
                Span(
                    unsafe_ptr=values.unsafe_ptr().unsafe_bitcast[UInt8](),
                    length=len(values) * 4,
                )
            )
        else:
            for value in values:
                self.write_f32(value)

    def write_f64(mut self, value: Float64):
        self.write_u64(bitcast[DType.uint64](value))

    def write_bytes(mut self, values: List[UInt8]):
        self._bytes.extend(Span(values))

    def update_crc32_and_clear(mut self, register: UInt32) -> UInt32:
        """Advance an unfinalized register, retaining capacity for the next chunk.
        """
        var result = crc32_update(register, Span(self._bytes))
        self._bytes.clear()
        return result

    def take_bytes(mut self) -> List[UInt8]:
        var result = self._bytes^
        self._bytes = List[UInt8]()
        return result^


@always_inline
def _read_unsigned_le[
    count: Int
](bytes: Span[UInt8, _], mut offset: Int) raises -> UInt64:
    comptime assert count == 1 or count == 2 or count == 4 or count == 8
    if count > len(bytes) - offset:
        raise Error("truncated binary value")
    var value = UInt64(0)
    comptime for i in range(count):
        value |= UInt64(bytes[offset + i]) << UInt64(i * 8)
    offset += count
    return value


def _read_f32s_le(
    bytes: Span[UInt8, _], mut offset: Int, count: Int
) raises -> List[Float32]:
    # Validate before allocation, multiplication or pointer construction.
    if offset < 0 or offset > len(bytes):
        raise Error("binary reader position is invalid")
    if count < 0 or count > (len(bytes) - offset) // 4:
        raise Error("truncated binary F32 tape")
    if count == 0:
        return List[Float32]()
    comptime if is_little_endian():
        var values = List[Float32](unsafe_uninit_length=count)
        # Byte pointers impose no alignment requirement on the source. The new
        # owned allocation cannot overlap it; every result bit is initialized.
        unsafe_memcpy(
            dest=values.unsafe_ptr().unsafe_bitcast[UInt8](),
            src=bytes.unsafe_ptr().unsafe_offset(offset),
            count=count * 4,
        )
        offset += count * 4
        return values^
    else:
        var values = List[Float32](capacity=count)
        for _ in range(count):
            values.append(
                bitcast[DType.float32](
                    UInt32(_read_unsigned_le[4](bytes, offset))
                )
            )
        return values^


struct BorrowedBinaryReader[origin: ImmOrigin](Movable):
    """Read bytes without copying or owning the source allocation.

    Finish all reader/subspan use before the owner is mutated or its buffer
    reused. Origins track provenance but do not prohibit every List mutation.
    """

    var _bytes: Span[UInt8, Self.origin]
    var _offset: Int

    def __init__(out self, bytes: Span[UInt8, Self.origin]):
        self._bytes = bytes
        self._offset = 0

    def remaining(self) -> Int:
        return len(self._bytes) - self._offset

    def position(self) -> Int:
        return self._offset

    def read_span(mut self, count: Int) raises -> Span[UInt8, Self.origin]:
        if count < 0 or count > self.remaining():
            raise Error("truncated binary value")
        var start = self._offset
        self._offset += count
        return self._bytes[start : self._offset]

    def read_u8(mut self) raises -> UInt8:
        return UInt8(_read_unsigned_le[1](self._bytes, self._offset))

    def read_u16(mut self) raises -> UInt16:
        return UInt16(_read_unsigned_le[2](self._bytes, self._offset))

    def read_u32(mut self) raises -> UInt32:
        return UInt32(_read_unsigned_le[4](self._bytes, self._offset))

    def read_u64(mut self) raises -> UInt64:
        return _read_unsigned_le[8](self._bytes, self._offset)

    def read_i64(mut self) raises -> Int64:
        return bitcast[DType.int64](self.read_u64())

    def read_f32(mut self) raises -> Float32:
        return bitcast[DType.float32](self.read_u32())

    def read_f32s(mut self, count: Int) raises -> List[Float32]:
        """Read an owned bit-exact F32 tape; bounds failures do not advance."""
        return _read_f32s_le(self._bytes, self._offset, count)

    def read_f64(mut self) raises -> Float64:
        return bitcast[DType.float64](self.read_u64())


struct BinaryReader:
    """A bounds-checked little-endian reader over owned bytes."""

    var _bytes: List[UInt8]
    var _offset: Int

    def __init__(out self, var bytes: List[UInt8]):
        self._bytes = bytes^
        self._offset = 0

    def remaining(self) -> Int:
        return len(self._bytes) - self._offset

    def position(self) -> Int:
        return self._offset

    def read_u8(mut self) raises -> UInt8:
        return UInt8(_read_unsigned_le[1](Span(self._bytes), self._offset))

    def read_u16(mut self) raises -> UInt16:
        return UInt16(_read_unsigned_le[2](Span(self._bytes), self._offset))

    def read_u32(mut self) raises -> UInt32:
        return UInt32(_read_unsigned_le[4](Span(self._bytes), self._offset))

    def read_u64(mut self) raises -> UInt64:
        return _read_unsigned_le[8](Span(self._bytes), self._offset)

    def read_i64(mut self) raises -> Int64:
        return bitcast[DType.int64](self.read_u64())

    def read_f32(mut self) raises -> Float32:
        return bitcast[DType.float32](self.read_u32())

    def read_f32s(mut self, count: Int) raises -> List[Float32]:
        """Read an owned bit-exact F32 tape; bounds failures do not advance."""
        return _read_f32s_le(Span(self._bytes), self._offset, count)

    def read_f64(mut self) raises -> Float64:
        return bitcast[DType.float64](self.read_u64())

    def read_bytes(mut self, count: Int) raises -> List[UInt8]:
        self._require(count)
        var result = List[UInt8](capacity=count)
        for _ in range(count):
            result.append(self._bytes[self._offset])
            self._offset += 1
        return result^

    def _require(self, count: Int) raises:
        if count < 0 or count > self.remaining():
            raise Error("truncated binary value")
