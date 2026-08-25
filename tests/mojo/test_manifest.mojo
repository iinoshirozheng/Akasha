from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import (
    decode_manifest_bytes,
    encode_manifest,
    load_manifest,
    publish_manifest,
    Manifest,
)
from std.testing import assert_equal, assert_raises, TestSuite


def test_manifest_binary_round_trip() raises:
    var bytes = encode_manifest(3, 9, 0x12345678, "segment-9.bin")
    var manifest = decode_manifest_bytes(bytes^, 3)

    assert_equal(manifest.dimension, 3)
    assert_equal(manifest.last_sequence, UInt64(9))
    assert_equal(manifest.segment_checksum, UInt32(0x12345678))
    assert_equal(manifest.segment_name, "segment-9.bin")


def test_manifest_rejects_truncation_checksum_and_version() raises:
    var truncated = encode_manifest(1, 1, 10, "segment-1.bin")
    _ = truncated.pop()
    with assert_raises():
        _ = decode_manifest_bytes(truncated^, 1)

    var corrupt = encode_manifest(1, 1, 10, "segment-1.bin")
    corrupt[12] ^= 0x01
    with assert_raises():
        _ = decode_manifest_bytes(corrupt^, 1)

    var version = encode_manifest(1, 1, 10, "segment-1.bin")
    version[4] = 2
    var checksum = crc32_range(version, 4, len(version) - 4)
    for byte_index in range(4):
        version[len(version) - 4 + byte_index] = UInt8(
            checksum >> UInt32(byte_index * 8)
        )
    with assert_raises():
        _ = decode_manifest_bytes(version^, 1)


def test_publish_atomically_replaces_manifest_and_removes_temp() raises:
    var directory = String("/tmp/akasha-phase3-manifest")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    var empty = List[UInt8]()
    write_file_sync(directory + "/segment-1.bin", empty)
    write_file_sync(directory + "/segment-2.bin", empty)

    var first = Manifest(1, 1, 11, "segment-1.bin")
    var second = Manifest(1, 2, 22, "segment-2.bin")
    publish_manifest(directory, first)
    publish_manifest(directory, second)
    var loaded = load_manifest(directory, 1)

    assert_equal(loaded.last_sequence, UInt64(2))
    assert_equal(loaded.segment_name, "segment-2.bin")
    assert_equal(path_exists(directory + "/manifest.bin.tmp"), False)

    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/segment-1.bin")
    remove_file_if_exists(directory + "/segment-2.bin")


def test_load_rejects_missing_referenced_segment() raises:
    var directory = String("/tmp/akasha-phase3-manifest-missing")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/segment-missing.bin")
    var manifest = Manifest(2, 3, 33, "segment-missing.bin")
    publish_manifest(directory, manifest)

    with assert_raises():
        _ = load_manifest(directory, 2)

    remove_file_if_exists(directory + "/manifest.bin")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
