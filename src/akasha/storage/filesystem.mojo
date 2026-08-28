from std.ffi import c_int, external_call
from std.os import makedirs, remove
from std.os.path import exists
from std.sys._libc_errno import get_errno


trait _DurableDirectoryOps:
    """Internal seam for durable collection-directory creation tests."""

    def exists(self, path: String) -> Bool:
        ...

    def make(mut self, path: String) raises:
        ...

    def sync(mut self, path: String) raises:
        ...


struct _FilesystemDirectoryOps(_DurableDirectoryOps):
    def __init__(out self):
        pass

    def exists(self, path: String) -> Bool:
        return exists(path)

    def make(mut self, path: String) raises:
        makedirs(path, exist_ok=True)

    def sync(mut self, path: String) raises:
        sync_directory(path)


def path_exists(path: String) -> Bool:
    return exists(path)


def ensure_directory(path: String) raises:
    makedirs(path, exist_ok=True)


def ensure_durable_directory(path: String) raises -> Bool:
    """Create a directory hierarchy and durably publish each new entry.

    Each directory and its immediate parent are fsynced, including on retry
    when a previous parent barrier may have failed. Returns whether this call
    created the requested leaf directory.
    """
    var parent = _parent_directory(path)
    var ops = _FilesystemDirectoryOps()
    if path_exists(path):
        return _ensure_durable_directory_with_ops(path, parent, ops)
    if parent != path:
        _ = ensure_durable_directory(parent)
    return _ensure_durable_directory_with_ops(path, parent, ops)


def _ensure_durable_directory_with_ops[Ops: _DurableDirectoryOps](
    path: String, parent: String, mut ops: Ops
) raises -> Bool:
    if ops.exists(path):
        ops.sync(path)
        if parent != path:
            ops.sync(parent)
        return False
    ops.make(path)
    ops.sync(path)
    ops.sync(parent)
    return True


def read_file_bytes(path: String) raises -> List[UInt8]:
    var file = open(path, "r")
    var bytes = file.read_bytes()
    file.close()
    return bytes^


def read_file_bytes_bounded(
    path: String, maximum_bytes: Int
) raises -> List[UInt8]:
    """Read at most one byte beyond a limit, then reject oversized files."""
    if maximum_bytes < 0 or maximum_bytes == Int.MAX:
        raise Error("bounded file read limit is invalid")
    # Mojo 1.0 FileHandle.read_bytes(size) stops after the requested size even
    # when the file is larger. The extra byte distinguishes exact-limit files.
    var bytes: List[UInt8]
    with open(path, "r") as file:
        bytes = file.read_bytes(maximum_bytes + 1)
    if len(bytes) > maximum_bytes:
        raise Error("file exceeds bounded read limit")
    return bytes^


def write_file_sync(path: String, bytes: List[UInt8]) raises:
    var file = open(path, "w")
    file.write_all(bytes)
    _sync_descriptor(file.handle)
    file.close()


def append_file_sync(path: String, bytes: List[UInt8]) raises:
    var file = open(path, "a")
    file.write_all(bytes)
    _sync_descriptor(file.handle)
    file.close()


def remove_file_if_exists(path: String) raises:
    if exists(path):
        remove(path)


def atomic_replace(source: String, destination: String) raises:
    var source_path = source
    var destination_path = destination
    var result = external_call["rename", c_int](
        source_path.as_c_string_slice(),
        destination_path.as_c_string_slice(),
    )
    if result != 0:
        raise Error("rename failed: " + String(get_errno()))


def sync_directory(path: String) raises:
    var directory = open(path, "r")
    _sync_descriptor(directory.handle)
    directory.close()


def _sync_descriptor(descriptor: Int) raises:
    var result = external_call["fsync", c_int](c_int(descriptor))
    if result != 0:
        raise Error("fsync failed: " + String(get_errno()))


def _parent_directory(path: String) raises -> String:
    var bytes = List[UInt8]()
    for byte in path.bytes():
        bytes.append(byte)
    if len(bytes) == 0:
        raise Error("directory path cannot be empty")
    var end = len(bytes)
    while end > 1 and bytes[end - 1] == UInt8(0x2F):
        end -= 1
    var slash = -1
    for index in range(end):
        if bytes[index] == UInt8(0x2F):
            slash = index
    if slash < 0:
        return "."
    if slash == 0:
        return "/"
    var parent = List[UInt8](capacity=slash)
    for index in range(slash):
        parent.append(bytes[index])
    return String(from_utf8=parent)
