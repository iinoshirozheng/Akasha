from std.ffi import c_int, external_call
from std.os import makedirs, remove
from std.os.path import exists
from std.sys._libc_errno import get_errno


def path_exists(path: String) -> Bool:
    return exists(path)


def ensure_directory(path: String) raises:
    makedirs(path, exist_ok=True)


def read_file_bytes(path: String) raises -> List[UInt8]:
    var file = open(path, "r")
    var bytes = file.read_bytes()
    file.close()
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


def _sync_descriptor(descriptor: Int) raises:
    var result = external_call["fsync", c_int](c_int(descriptor))
    if result != 0:
        raise Error("fsync failed: " + String(get_errno()))
