from std.io.file import FileHandle
from std.os import SEEK_END


comptime _READ_AHEAD_BYTES = 64 * 1024


struct WalReadBuffer(Movable):
    """Shared bounded file acquisition for legacy and field-aware WAL readers.

    Decode every borrowed span before ensure_available can resize or compact
    the buffer. Callers hold collection exclusion and advance only after a
    complete envelope is accepted; this buffer neither decodes nor repairs.
    """

    var _file: FileHandle
    var _bytes: List[UInt8]
    var _offset: Int
    var source_length: Int

    def __init__(out self, path: String, source_exists: Bool) raises:
        self._file = FileHandle()
        self._bytes = List[UInt8]()
        self._offset = 0
        self.source_length = 0
        if not source_exists:
            return
        self._file = open(path, "r")
        var length = self._file.seek(0, SEEK_END)
        if length > UInt64(Int.MAX):
            raise Error("WAL file is too large")
        self.source_length = Int(length)
        _ = self._file.seek(0)

    def bytes(self) -> Span[UInt8, origin_of(self._bytes)]:
        return Span(self._bytes)[self._offset :]

    def capacity(self) -> Int:
        return self._bytes.capacity()

    def consume(mut self, count: Int) raises:
        if count < 0 or count > len(self._bytes) - self._offset:
            raise Error("invalid WAL buffer consumption")
        self._offset += count

    def ensure_available(mut self, count: Int, accepted_length: Int) raises:
        if accepted_length < 0 or accepted_length > self.source_length:
            raise Error("invalid accepted WAL length")
        var remaining = self.source_length - accepted_length
        if count < 0 or count > remaining:
            raise Error("WAL read exceeds captured file length")
        var retained = len(self._bytes) - self._offset
        if retained >= count:
            return
        # A prefix crossing a read boundary is the only retained-byte copy.
        if self._offset > 0:
            for index in range(retained):
                self._bytes[index] = self._bytes[self._offset + index]
        var target = min(remaining, max(_READ_AHEAD_BYTES, count))
        self._bytes.resize(target, 0)
        self._offset = 0
        var read = retained
        while read < target:
            var received = self._file.read(Span(self._bytes)[read:])
            if received == 0:
                raise Error("WAL changed during preflight")
            read += received
