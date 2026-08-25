from std.memory import bitcast


def crc32(data: List[UInt8]) -> UInt32:
    """Compute CRC-32/ISO-HDLC over an owned byte list."""
    return crc32_range(data, 0, len(data))


def crc32_range(data: List[UInt8], start: Int, end: Int) -> UInt32:
    """Compute CRC-32/ISO-HDLC over ``[start, end)``."""
    var checksum = UInt32(0xFFFFFFFF)
    for index in range(start, end):
        checksum ^= UInt32(data[index])
        for _ in range(8):
            if checksum & 1:
                checksum = (checksum >> 1) ^ UInt32(0xEDB88320)
            else:
                checksum >>= 1
    return ~checksum


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

    def write_f64(mut self, value: Float64):
        self.write_u64(bitcast[DType.uint64](value))

    def write_bytes(mut self, values: List[UInt8]):
        for value in values:
            self._bytes.append(value)

    def take_bytes(mut self) -> List[UInt8]:
        var result = self._bytes^
        self._bytes = List[UInt8]()
        return result^


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
        self._require(1)
        var value = self._bytes[self._offset]
        self._offset += 1
        return value

    def read_u16(mut self) raises -> UInt16:
        self._require(2)
        var value = UInt16(0)
        for shift in range(0, 16, 8):
            value |= UInt16(self._bytes[self._offset]) << UInt16(shift)
            self._offset += 1
        return value

    def read_u32(mut self) raises -> UInt32:
        self._require(4)
        var value = UInt32(0)
        for shift in range(0, 32, 8):
            value |= UInt32(self._bytes[self._offset]) << UInt32(shift)
            self._offset += 1
        return value

    def read_u64(mut self) raises -> UInt64:
        self._require(8)
        var value = UInt64(0)
        for shift in range(0, 64, 8):
            value |= UInt64(self._bytes[self._offset]) << UInt64(shift)
            self._offset += 1
        return value

    def read_i64(mut self) raises -> Int64:
        return bitcast[DType.int64](self.read_u64())

    def read_f32(mut self) raises -> Float32:
        return bitcast[DType.float32](self.read_u32())

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
        if count < 0 or self._offset + count > len(self._bytes):
            raise Error("truncated binary value")
