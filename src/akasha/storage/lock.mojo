from std.ffi import c_int, external_call
from std.sys._libc_errno import get_errno


comptime _LOCK_EX = 2
comptime _LOCK_NB = 4
comptime _LOCK_UN = 8


struct CollectionLock(Movable):
    """A process-scoped advisory exclusive lock on one stable file."""

    var _file: FileHandle
    var _locked: Bool

    def __init__(out self, var file: FileHandle):
        self._file = file^
        self._locked = True

    @staticmethod
    def acquire(path: String) raises -> CollectionLock:
        var file = open(path, "a")
        var result = external_call["flock", c_int](
            c_int(file.handle), c_int(_LOCK_EX | _LOCK_NB)
        )
        if result != 0:
            file.close()
            raise Error(
                "collection is already open: " + String(get_errno())
            )
        return CollectionLock(file^)

    def close(mut self) raises:
        if not self._locked:
            return
        _ = external_call["flock", c_int](
            c_int(self._file.handle), c_int(_LOCK_UN)
        )
        self._file.close()
        self._locked = False

    def __deinit__(deinit self):
        if self._locked:
            _ = external_call["flock", c_int](
                c_int(self._file.handle), c_int(_LOCK_UN)
            )
