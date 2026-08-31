from std.ffi import c_int, c_long, c_size_t, external_call
from std.io.file import O_RDONLY
from std.memory.alloc import alloc, Layout
from std.stat import S_ISREG
from std.sys.info import CompilationTarget, is_triple, platform_map
from std.sys._libc_errno import get_errno


# POSIX values are identical on Darwin and Linux, but keep them named here so
# the ABI boundary is explicit and auditable alongside the stat layout below.
comptime _PROT_READ = 1
comptime _MAP_PRIVATE = platform_map["MAP_PRIVATE", linux=2, macos=2]()

# `fstat` writes the platform C `struct stat`. Akasha's supported Pixi hosts are
# 64-bit macOS ARM64 and Linux x86-64. Both structs are 144 bytes, while the
# signed 64-bit `st_size` field is at the platform-specific offset below.
comptime _STAT_BYTES = platform_map["struct stat size", linux=144, macos=144]()
comptime _STAT_SIZE_OFFSET = platform_map[
    "struct stat st_size offset", linux=48, macos=96
]()
comptime _STAT_MODE_OFFSET = platform_map[
    "struct stat st_mode offset", linux=24, macos=4
]()
comptime _STAT_MODE_BYTES = platform_map[
    "struct stat st_mode bytes", linux=4, macos=2
]()
comptime _STAT_WORDS = _STAT_BYTES // 8


struct MappedFile(Movable):
    """Owns one validated read-only private POSIX file mapping."""

    var _base: Optional[Pointer[UInt8, ImmUntrackedOrigin]]
    var _length: Int
    var _descriptor: Int32
    var _closed: Bool

    def __init__(
        out self,
        base: Optional[Pointer[UInt8, ImmUntrackedOrigin]],
        length: Int,
        descriptor: Int32,
    ):
        self._base = base
        self._length = length
        self._descriptor = descriptor
        self._closed = False

    def __init__(out self, *, deinit move: Self):
        """Transfers the sole mapping ownership and disarms the source."""
        self._base = move._base
        self._length = move._length
        self._descriptor = move._descriptor
        self._closed = move._closed

    @staticmethod
    def open_readonly(path: String) raises -> MappedFile:
        """Opens and maps a supported 64-bit POSIX regular byte stream."""
        comptime if CompilationTarget.is_linux():
            comptime assert is_triple[
                "x86_64-unknown-linux-gnu"
            ](), "MappedFile currently supports Linux x86-64 only"
        elif CompilationTarget.is_macos():
            comptime assert (
                CompilationTarget.is_apple_silicon()
            ), "MappedFile currently supports macOS ARM64 only"
        else:
            comptime assert (
                False
            ), "MappedFile supports only macOS ARM64 and Linux x86-64"

        var owned_path = path
        var descriptor = external_call["open", c_int, num_fixed_args=2](
            owned_path.as_c_string_slice().unsafe_ptr(), c_int(O_RDONLY)
        )
        if descriptor < 0:
            raise Error("open readonly mapping failed: " + String(get_errno()))

        # Allocate as native 64-bit words so the st_size load is aligned. The
        # C call still receives the same address and writes `_STAT_BYTES` bytes.
        var stat_storage = alloc(Layout[Int](count=_STAT_WORDS)).into_managed()
        var stat_words = stat_storage.unsafe_ptr()
        var stat_status = external_call["fstat", c_int](descriptor, stat_words)
        if stat_status != 0:
            var error_number = get_errno()
            _ = external_call["close", c_int](descriptor)
            raise Error(
                "fstat for readonly mapping failed: " + String(error_number)
            )

        var stat_bytes = stat_words.unsafe_bitcast[UInt8]()
        var mode = UInt32(0)
        for index in range(_STAT_MODE_BYTES):
            mode |= UInt32(
                stat_bytes[unsafe_offset=_STAT_MODE_OFFSET + index]
            ) << UInt32(index * 8)
        if not S_ISREG(Int(mode)):
            _ = external_call["close", c_int](descriptor)
            raise Error("readonly mapping requires a regular file")

        var length = stat_words[unsafe_offset=_STAT_SIZE_OFFSET // 8]
        if length < 0:
            _ = external_call["close", c_int](descriptor)
            raise Error("readonly mapping file length is negative")

        # POSIX mmap rejects a zero length. Keep the descriptor under the same
        # RAII owner and represent the empty file without a base pointer.
        if length == 0:
            return MappedFile(None, 0, descriptor)

        var null_address: Optional[OpaquePointer[MutUntrackedOrigin]] = None
        var mapped = external_call["mmap", OpaquePointer[MutUntrackedOrigin]](
            null_address,
            c_size_t(length),
            c_int(_PROT_READ),
            c_int(_MAP_PRIVATE),
            descriptor,
            c_long(0),
        )
        if Int(mapped) == -1:
            var error_number = get_errno()
            _ = external_call["close", c_int](descriptor)
            raise Error("readonly mmap failed: " + String(error_number))

        var bytes = mapped.unsafe_bitcast[UInt8]().as_imm()
        return MappedFile(bytes, length, descriptor)

    def __deinit__(deinit self):
        self._close()

    def byte_length(self) -> Int:
        """Returns the file byte length, including zero for an empty file."""
        return self._length

    def byte_at(self, offset: Int) raises -> UInt8:
        """Reads one byte after validating open state and bounds."""
        self._ensure_open()
        if offset < 0 or offset >= self._length:
            raise Error("mapped byte offset is out of bounds")
        return self._base.value()[unsafe_offset=offset]

    def checked_slice(
        ref self, offset: UInt64, length: UInt64
    ) raises -> MappedBytes[origin_of(self)]:
        """Returns an owner-borrowing byte range after overflow-safe checks."""
        self._ensure_open()
        var file_length = UInt64(self._length)
        if offset > file_length:
            raise Error("mapped slice offset is out of bounds")
        # Subtraction avoids wrapping `offset + length` before validation.
        if length > file_length - offset:
            raise Error("mapped slice length is out of bounds")
        return MappedBytes(Pointer(to=self), Int(offset), Int(length))

    def close(mut self):
        """Releases mapping and descriptor ownership; safe to call repeatedly.
        """
        self._close()

    def _ensure_open(self) raises:
        if self._closed:
            raise Error("mapped file is closed")

    def _close(mut self):
        if self._closed:
            return
        if self._base:
            _ = external_call["munmap", c_int](
                self._base.value(), c_size_t(self._length)
            )
        if self._descriptor >= 0:
            _ = external_call["close", c_int](c_int(self._descriptor))
        self._base = None
        self._length = 0
        self._descriptor = -1
        self._closed = True


struct MappedBytes[origin: Origin](Movable):
    """A checked byte range that borrows its mapping owner, never a raw pointer.
    """

    var _owner: Pointer[MappedFile, Self.origin]
    var _offset: Int
    var _length: Int

    def __init__(
        out self,
        owner: Pointer[MappedFile, Self.origin],
        offset: Int,
        length: Int,
    ):
        self._owner = owner
        self._offset = offset
        self._length = length

    def byte_length(self) -> Int:
        return self._length

    def byte_at(self, offset: Int) raises -> UInt8:
        if offset < 0 or offset >= self._length:
            raise Error("mapped slice byte offset is out of bounds")
        return self._owner[].byte_at(self._offset + offset)
