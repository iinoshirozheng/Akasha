"""Pinned Mojo capability probe for #62; this is not the WAL decoder.

Borrowed spans retain source origins but do not freeze an owning List against
all future method calls. Production decoding must finish before buffer reuse.
"""

from akasha.storage.filesystem import (
    append_file_sync,
    read_file_bytes,
    remove_file_if_exists,
    sync_file,
)
from std.ffi import c_int, c_long, external_call
from std.os import SEEK_END
from std.sys import size_of
from std.testing import assert_equal, assert_raises


struct BorrowedReader[origin: ImmOrigin](Movable):
    var data: Span[UInt8, Self.origin]
    var offset: Int

    def __init__(out self, data: Span[UInt8, Self.origin]):
        self.data = data
        self.offset = 0

    def remaining(self) -> Int:
        return len(self.data) - self.offset

    def read_span(mut self, count: Int) raises -> Span[UInt8, Self.origin]:
        if count < 0 or count > self.remaining():
            raise Error("truncated binary value")
        var start = self.offset
        self.offset += count
        return self.data[start : self.offset]

    def read_u32(mut self) raises -> UInt32:
        var bytes = self.read_span(4)
        var result = UInt32(0)
        for i in range(4):
            result |= UInt32(bytes[i]) << UInt32(i * 8)
        return result


def check(bytes: List[UInt8]) raises:
    var reader = BorrowedReader(Span(bytes))
    assert_equal(reader.read_u32(), UInt32(0x04030201))
    var suffix = reader.read_span(3)
    assert_equal(Int(suffix.unsafe_ptr()), Int(bytes.unsafe_ptr()) + 4)
    assert_equal(String(from_utf8=suffix), "abc")
    assert_equal(reader.remaining(), 0)
    with assert_raises():
        _ = reader.read_span(1)
    with assert_raises():
        _ = reader.read_span(Int.MAX)
    with assert_raises():
        _ = reader.read_span(-1)
    assert_equal(len(reader.read_span(0)), 0)


def check_file_io() raises:
    comptime assert size_of[c_long]() == 8, "64-bit POSIX off_t required"
    var path = (
        "/tmp/akasha-wal-api-probe-"
        + String(Int(external_call["getpid", c_int]()))
        + ".bin"
    )
    var bytes: List[UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    with open(path, "w") as output:
        output.write_all(Span(bytes))
        sync_file(output)
    # Mojo 1.0 accepts rw, not Python's r+. It does not expose truncate.
    with open(path, "rw") as file:
        assert_equal(Int(file.seek(0, SEEK_END)), 8)
        assert_equal(
            external_call["ftruncate", c_int](c_int(file.handle), c_long(4)),
            c_int(0),
        )
        sync_file(file)
        _ = file.seek(0)
        var buffer = List[UInt8](length=8, fill=0)
        assert_equal(file.read(Span(buffer)), 4)
        assert_equal(file.read(Span(buffer)[4:]), 0)
        for i in range(4):
            assert_equal(buffer[i], UInt8(i + 1))
    append_file_sync(path, [UInt8(9)])
    var result = read_file_bytes(path)
    assert_equal(len(result), 5)
    for i in range(4):
        assert_equal(result[i], UInt8(i + 1))
    assert_equal(result[4], UInt8(9))
    remove_file_if_exists(path)
    print(
        "PASS bounded read/EOF, descriptor truncate/fsync, append after repair"
    )


def main() raises:
    var owner: List[UInt8] = [1, 2, 3, 4, 97, 98, 99]
    check(owner)
    check_file_io()
    assert_equal(owner[0], UInt8(1))
    print(
        "PASS origin-tracked reader, borrowed subspan, direct UTF-8, overflow"
        " bounds"
    )
