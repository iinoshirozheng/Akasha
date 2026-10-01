"""Exact immutable-file leases that survive their collection and its writer.

One generation shares these open descriptors. Advisory shared locks let another
collection instance distinguish a live reader from an unreferenced job output.
Directory-relative opens and unlinks keep cleanup attached to the original
directory even if the caller later renames or replaces its path.
"""

from akasha.storage.filesystem import sync_file
from akasha.storage.manifest import (
    _canonical_u64,
    decode_manifest_bytes,
    Manifest,
    parse_hnsw_job_name,
    read_manifest_bytes,
)
from std.ffi import c_int, external_call
from std.io.file import O_RDONLY
from std.os import listdir
from std.sys._libc_errno import ErrNo, get_errno


comptime _LOCK_SH = 1
comptime _LOCK_EX = 2
comptime _LOCK_NB = 4


def _open_at(
    directory: FileHandle, name: String
) raises -> Optional[FileHandle]:
    var owned_name = name.copy()
    var fd = external_call["openat", c_int, num_fixed_args=3](
        c_int(directory.handle), owned_name.as_c_string_slice(), c_int(O_RDONLY)
    )
    if fd < 0:
        var error = get_errno()
        if error == ErrNo.ENOENT:
            return None
        raise Error("open leased file failed: " + String(error))
    var file = FileHandle()
    file.handle = Int(fd)
    return Optional(file^)


def _lock(file: FileHandle, exclusive: Bool) raises -> Bool:
    var result = external_call["flock", c_int](
        c_int(file.handle),
        c_int((_LOCK_EX if exclusive else _LOCK_SH) | _LOCK_NB),
    )
    if result == 0:
        return True
    var error = get_errno()
    if error == ErrNo.EWOULDBLOCK:
        return False
    raise Error("immutable file lease failed: " + String(error))


def _unlink_at(directory: FileHandle, name: String) raises:
    var owned_name = name.copy()
    if (
        external_call["unlinkat", c_int](
            c_int(directory.handle), owned_name.as_c_string_slice(), c_int(0)
        )
        != 0
    ):
        var error = get_errno()
        if error != ErrNo.ENOENT:
            raise Error("retired file unlink failed: " + String(error))


def _manifest_names(manifest: Manifest) -> Dict[String, Bool]:
    var names = Dict[String, Bool]()
    for index in range(len(manifest.segments)):
        names[manifest.segments[index].name] = True
        if manifest.segments[index].sparse_name.byte_length() > 0:
            names[manifest.segments[index].sparse_name] = True
    if manifest.hnsw_name:
        names[manifest.hnsw_name.value()] = True
    return names^


struct ManifestFileLease(Movable):
    var directory: FileHandle
    var dimension: Int
    var names: List[String]
    var files: List[FileHandle]

    def __init__(
        out self, path: String, dimension: Int, generation: UInt64
    ) raises:
        var directory = open(path, "r")
        var manifest_file = _open_at(directory, "manifest.bin")
        if not manifest_file:
            raise Error("cannot lease a missing manifest")
        var manifest = decode_manifest_bytes(
            read_manifest_bytes(manifest_file.value()), dimension
        )
        if manifest.generation != generation:
            raise Error("cannot lease a different manifest generation")
        var names = List[String]()
        var files = List[FileHandle]()
        var referenced = _manifest_names(manifest)
        for name in referenced:
            var file = _open_at(directory, name)
            if not file:
                if manifest.hnsw_name and name == manifest.hnsw_name.value():
                    continue  # Missing derived state may be rebuilt on open.
                raise Error("cannot lease a missing authoritative file")
            if not _lock(file.value(), False):
                raise Error("cannot lease an immutable file during reclamation")
            names.append(name.copy())
            files.append(file.take())
        self.directory = directory^
        self.dimension = dimension
        self.names = names^
        self.files = files^

    def reclaim(self) raises:
        """On the last pin, unlink only obsolete files without another lease."""
        var file = _open_at(self.directory, "manifest.bin")
        if not file:
            return  # No authority: never guess which files should be removed.
        var manifest = decode_manifest_bytes(
            read_manifest_bytes(file.value()), self.dimension
        )
        var referenced = _manifest_names(manifest)
        var removed = False
        for index in range(len(self.names)):
            if self.names[index] in referenced:
                continue
            if _lock(self.files[index], True):
                _unlink_at(self.directory, self.names[index])
                removed = True
        if removed:
            sync_file(self.directory)


def try_reclaim_file(directory: FileHandle, name: String) raises -> Bool:
    """Caller proved this name obsolete; a live lease defers deletion."""
    var file = _open_at(directory, name)
    if not file:
        return True
    if not _lock(file.value(), True):
        return False
    _unlink_at(directory, name)
    return True


def _is_job_output(name: String) -> Bool:
    var base = String(name.removesuffix(".tmp"))
    try:
        if base.startswith("hnsw-"):
            return parse_hnsw_job_name(base)[1] > 0
        if base.startswith("point-base-") or base.startswith("point-delta-"):
            var point_body = String(
                base.removeprefix("point-base-") if base.startswith(
                    "point-base-"
                ) else base.removeprefix("point-delta-")
            )
            if not point_body.endswith(".bin"):
                return False
            var parts = point_body.removesuffix(".bin").split("-")
            if len(parts) != 3:
                return False
            _ = _canonical_u64(String(parts[0]))
            var generation = _canonical_u64(String(parts[1]))
            _ = _canonical_u64(String(parts[2]))
            return generation > 0
        var body: String
        if base.startswith("segment-compact-"):
            body = String(base.removeprefix("segment-compact-"))
        elif base.startswith("sparse-compact-"):
            body = String(base.removeprefix("sparse-compact-"))
        else:
            return False
        if not body.endswith(".bin"):
            return False
        var parts = body.removesuffix(".bin").split("-")
        if len(parts) != 2:
            return False
        var generation = _canonical_u64(String(parts[0]))
        _ = _canonical_u64(String(parts[1]))
        return generation > 0
    except:
        return False


def reclaim_unreferenced_job_files(path: String, dimension: Int) raises:
    """Open-time cleanup under the source writer lock, before starting jobs.

    All generations are eligible, but current manifest references and live
    file leases are excluded. Unknown and legacy sequence-only names stay.
    """
    var directory = open(path, "r")
    var file = _open_at(directory, "manifest.bin")
    var referenced = Dict[String, Bool]()
    if file:
        var manifest = decode_manifest_bytes(
            read_manifest_bytes(file.value()), dimension
        )
        referenced = _manifest_names(manifest)
    var removed = False
    for name in listdir(path):
        if name not in referenced and _is_job_output(name):
            if try_reclaim_file(directory, name):
                removed = True
    if removed:
        sync_file(directory)
