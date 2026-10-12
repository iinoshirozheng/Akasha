from akasha.storage.checksum import BinaryReaderSource
from akasha.storage.mapped_file import MappedFile
from std.memory import bitcast
from std.sys import size_of


struct MappedBinaryReader[origin: ImmOrigin](BinaryReaderSource):
    """Decode from a borrowed mapping, returning only independent owned values.
    """

    var _file: Pointer[MappedFile, Self.origin]
    var _offset: Int

    def __init__(out self, mapping: Pointer[MappedFile, Self.origin]):
        self._file = mapping
        self._offset = 0

    def remaining(self) -> Int:
        return self._file[].byte_length() - self._offset

    def position(self) -> Int:
        return self._offset

    def _read[dtype: DType](mut self) raises -> Scalar[dtype]:
        var value = self._file[].load_scalars[dtype, 1](self._offset)
        self._offset += size_of[Scalar[dtype]]()
        return value

    def read_u8(mut self) raises -> UInt8:
        return self._read[DType.uint8]()

    def read_u16(mut self) raises -> UInt16:
        return self._read[DType.uint16]()

    def read_u32(mut self) raises -> UInt32:
        return self._read[DType.uint32]()

    def read_u64(mut self) raises -> UInt64:
        return self._read[DType.uint64]()

    def read_i64(mut self) raises -> Int64:
        return bitcast[DType.int64](self.read_u64())

    def read_f32s(mut self, count: Int) raises -> List[Float32]:
        var values = self._file[].copy_scalars[DType.float32](
            self._offset, count
        )
        self._offset += count * 4
        return values^

    def read_bytes(mut self, count: Int) raises -> List[UInt8]:
        var values = self._file[].copy_scalars[DType.uint8](self._offset, count)
        self._offset += count
        return values^
