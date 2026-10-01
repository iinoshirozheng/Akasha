from akasha.common.config import CollectionConfig
from akasha.storage.checksum import CRC32_INITIAL, crc32_update
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.manifest import Manifest, SegmentDescriptor
from akasha.storage.operations import CheckpointCopy, copy_checkpoint
from std.ffi import c_int, external_call
from std.os import listdir
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, TestSuite


comptime _MIB = 1 << 20
comptime _NAME = "segment-base-7.bin"


def _reset(path: String) raises:
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)


def _peak_rss_bytes() -> Int:
    var usage = List[Int64](length=32, fill=0)
    _ = external_call["getrusage", c_int](c_int(0), usage.unsafe_ptr())
    # ru_maxrss follows the two struct timeval fields.
    var peak = Int(usage[4])
    comptime if CompilationTarget.is_macos():
        return peak
    else:
        return peak * 1024


def _write_segment(path: String, size: Int) raises -> UInt32:
    """Write a checksummed dense segment image one MiB at a time."""
    var chunk = List[UInt8](length=_MIB, fill=0x5A)
    var register = CRC32_INITIAL
    with open(path, "w") as file:
        file.write_all("AKSG".as_bytes())
        var remaining = size - 8
        while remaining > 0:
            var count = min(remaining, _MIB)
            register = crc32_update(register, Span(chunk)[:count])
            file.write_all(Span(chunk)[:count])
            remaining -= count
        var checksum = ~register
        var tail = List[UInt8]()
        for shift in range(0, 32, 8):
            tail.append(UInt8(checksum >> UInt32(shift)))
        file.write_all(Span(tail))
        return checksum


def _checkpoint(checksum: UInt32) raises -> CheckpointCopy:
    var segments = List[SegmentDescriptor]()
    segments.append(SegmentDescriptor(1, 0, 7, checksum, _NAME))
    return CheckpointCopy(
        Manifest.with_segments(1, 1, 7, segments^),
        Optional[CollectionConfig](),
        0,
    )


def _file_checksum(path: String) raises -> UInt32:
    var chunk = List[UInt8](length=_MIB, fill=0)
    var register = CRC32_INITIAL
    with open(path, "r") as file:
        while True:
            var count = file.read(Span(chunk))
            if count == 0:
                break
            register = crc32_update(register, Span(chunk)[:count])
    return ~register


def test_backup_copy_peak_memory_does_not_grow_with_file_size() raises:
    var source = String("/tmp/akasha-53-backup-memory-source")
    var warm = String("/tmp/akasha-53-backup-memory-warm")
    var target = String("/tmp/akasha-53-backup-memory-target")
    _reset(source)
    _reset(warm)
    _reset(target)
    var small = _write_segment(source + "/" + _NAME, 4 * _MIB)
    copy_checkpoint(source, warm, _checkpoint(small))

    var size = 128 * _MIB
    var large = _write_segment(source + "/" + _NAME, size)
    var before = _peak_rss_bytes()
    copy_checkpoint(source, target, _checkpoint(large))
    var growth = _peak_rss_bytes() - before
    assert_true(
        growth < 32 * _MIB,
        "copying 128 MiB raised peak RSS by " + String(growth) + " bytes",
    )
    assert_equal(
        _file_checksum(target + "/" + _NAME),
        _file_checksum(source + "/" + _NAME),
    )
    _reset(source)
    _reset(warm)
    _reset(target)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
