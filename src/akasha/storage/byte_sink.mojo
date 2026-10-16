"""Borrowed byte output shared by owned and streamed storage encoders."""

from akasha.storage.checksum import BinaryWriter, CRC32_INITIAL, crc32_update
from std.io import FileHandle


trait ByteSink(Movable):
    def write(mut self, bytes: Span[UInt8, _]) raises:
        ...


struct OwnedByteSink(ByteSink):
    var bytes: List[UInt8]

    def __init__(out self, capacity: Int):
        self.bytes = List[UInt8](capacity=capacity)

    def write(mut self, bytes: Span[UInt8, _]) raises:
        self.bytes.extend(bytes)

    def take_bytes(mut self) -> List[UInt8]:
        var result = self.bytes^
        self.bytes = List[UInt8]()
        return result^


struct FileByteSink[origin: MutOrigin](ByteSink):
    var _file: Pointer[FileHandle, Self.origin]

    def __init__(out self, ref[Self.origin] file: FileHandle):
        self._file = Pointer(to=file)

    def write(mut self, bytes: Span[UInt8, _]) raises:
        self._file[].write_all(bytes)


struct CheckedByteSink[Sink: ByteSink, origin: MutOrigin](ByteSink):
    """Track emitted bytes and CRC; nesting includes inner format footers."""

    var _sink: Pointer[Self.Sink, Self.origin]
    var register: UInt32
    var byte_length: UInt64

    def __init__(out self, ref[Self.origin] sink: Self.Sink):
        self._sink = Pointer(to=sink)
        self.register = CRC32_INITIAL
        self.byte_length = 0

    def write(mut self, bytes: Span[UInt8, _]) raises:
        self._sink[].write(bytes)
        self.register = crc32_update(self.register, bytes)
        self.byte_length += UInt64(len(bytes))


def drain_bytes(mut writer: BinaryWriter, mut sink: Some[ByteSink]) raises:
    var bytes = writer.take_bytes()
    if len(bytes) != 0:
        sink.write(Span(bytes))


def write_checksum(mut sink: Some[ByteSink], checksum: UInt32) raises:
    var footer = BinaryWriter()
    footer.write_u32(checksum)
    drain_bytes(footer, sink)
