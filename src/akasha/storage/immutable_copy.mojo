"""Bounded CRC-verified copies of immutable checkpoint files."""

from akasha.storage.checksum import CRC32_INITIAL, crc32_update
from akasha.storage.filesystem import atomic_replace, sync_file
from std.os import SEEK_END


def copy_verified_immutable(
    source: String,
    target: String,
    name: String,
    magic: StaticString,
    checksum: UInt32,
    mut buffer: List[UInt8],
    *,
    hnsw_identity: Optional[Tuple[UInt64, UInt64, UInt64]] = None,
    target_name: String = "",
) raises:
    """Stream one immutable file into place through ``buffer``.

    Segment CRCs exclude magic; HNSW CRCs include it. A retained 64-byte
    prefix also validates the captured HNSW sequence/config/live count.
    No graph mapping or whole-file allocation occurs on this copy path.
    """
    var prefix = List[UInt8](length=64 if hnsw_identity else 0, fill=0)
    var destination = (
        target + "/" + (name if target_name.byte_length() == 0 else target_name)
    )
    var temporary = destination + ".tmp"
    with open(source + "/" + name, "r") as input:
        var size = Int(input.seek(0, SEEK_END))
        _ = input.seek(0)
        if size < 8:
            raise Error("truncated immutable file: " + name)
        var tail_start = size - 4
        var register = CRC32_INITIAL
        var stored = UInt32(0)
        var offset = 0
        with open(temporary, "w") as output:
            while True:
                var count = input.read(Span(buffer))
                if count == 0:
                    break
                var end = offset + count
                if end > size:
                    raise Error("immutable file grew while copied: " + name)
                var bytes = Span(buffer)[:count]
                for position in range(offset, min(end, 4)):
                    if bytes[position - offset] != magic.as_bytes()[position]:
                        raise Error("immutable file magic mismatch: " + name)
                for position in range(offset, min(end, len(prefix))):
                    prefix[position] = bytes[position - offset]
                var body_start = max(offset, 0 if hnsw_identity else 4)
                var body_end = min(end, tail_start)
                if body_start < body_end:
                    register = crc32_update(
                        register,
                        bytes[body_start - offset : body_end - offset],
                    )
                for position in range(max(offset, tail_start), end):
                    stored |= UInt32(bytes[position - offset]) << UInt32(
                        8 * (position - tail_start)
                    )
                output.write_all(bytes)
                offset = end
            if offset != size:
                raise Error("immutable file shrank while copied: " + name)
            if stored != checksum or ~register != checksum:
                raise Error("immutable file checksum mismatch: " + name)
            if hnsw_identity:
                var version = _prefix_u64(prefix, 4, 2)
                var expected_header = UInt64(160 if version == 1 else 192)
                if (
                    size < Int(expected_header) + 4
                    or (version != 1 and version != 2)
                    or _prefix_u64(prefix, 6, 2) != 0
                    or _prefix_u64(prefix, 8, 4) != expected_header
                    or _prefix_u64(prefix, 12, 4) != 0
                    or _prefix_u64(prefix, 24, 8) != hnsw_identity.value()[0]
                    or _prefix_u64(prefix, 16, 8) != hnsw_identity.value()[1]
                    or _prefix_u64(prefix, 56, 8) != hnsw_identity.value()[2]
                ):
                    raise Error(
                        "HNSW copy header does not match captured manifest"
                    )
            sync_file(output)
    atomic_replace(temporary, destination)


def _prefix_u64(bytes: List[UInt8], offset: Int, width: Int) -> UInt64:
    var value = UInt64(0)
    for i in range(width):
        value |= UInt64(bytes[offset + i]) << UInt64(8 * i)
    return value
