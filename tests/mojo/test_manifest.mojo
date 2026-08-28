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
    encode_manifest_v2,
    encode_manifest_v3,
    load_manifest,
    publish_manifest,
    Manifest,
    SegmentDescriptor,
)
from std.testing import assert_equal, assert_raises, TestSuite


def _v3_segments() raises -> List[SegmentDescriptor]:
    var segments = List[SegmentDescriptor]()
    segments.append(
        SegmentDescriptor(1, 0, 3, 0x11111111, "segment-base-3.bin")
    )
    segments.append(
        SegmentDescriptor.with_sparse(
            0,
            4,
            5,
            0x22222222,
            "segment-delta-5.bin",
            0x33333333,
            "sparse-delta-5.bin",
        )
    )
    return segments^


def test_manifest_binary_round_trip() raises:
    var bytes = encode_manifest(3, 9, 0x12345678, "segment-9.bin")
    var manifest = decode_manifest_bytes(bytes^, 3)

    assert_equal(manifest.dimension, 3)
    assert_equal(manifest.last_sequence, UInt64(9))
    assert_equal(manifest.segment_checksum, UInt32(0x12345678))
    assert_equal(manifest.segment_name, "segment-9.bin")
    assert_equal(manifest.format_version, 1)
    assert_equal(len(manifest.segments), 1)
    assert_equal(manifest.segments[0].level, 1)
    assert_equal(manifest.segments[0].max_sequence, UInt64(9))


def test_manifest_v2_round_trips_ordered_segment_descriptors() raises:
    var segments = List[SegmentDescriptor]()
    segments.append(
        SegmentDescriptor(1, 0, 3, 0x11111111, "segment-base-3.bin")
    )
    segments.append(
        SegmentDescriptor.with_sparse(
            0,
            4,
            5,
            0x22222222,
            "segment-delta-5.bin",
            0x33333333,
            "sparse-delta-5.bin",
        )
    )
    var manifest = Manifest.with_segments(3, 7, 5, segments^)
    var bytes = encode_manifest_v2(manifest)
    var decoded = decode_manifest_bytes(bytes^, 3)

    assert_equal(decoded.format_version, 2)
    assert_equal(decoded.generation, UInt64(7))
    assert_equal(decoded.last_sequence, UInt64(5))
    assert_equal(len(decoded.segments), 2)
    assert_equal(decoded.segments[0].level, 1)
    assert_equal(decoded.segments[0].min_sequence, UInt64(0))
    assert_equal(decoded.segments[0].max_sequence, UInt64(3))
    assert_equal(decoded.segments[0].checksum, UInt32(0x11111111))
    assert_equal(decoded.segments[1].level, 0)
    assert_equal(decoded.segments[1].name, "segment-delta-5.bin")
    assert_equal(decoded.segments[1].sparse_checksum, UInt32(0x33333333))
    assert_equal(decoded.segments[1].sparse_name, "sparse-delta-5.bin")
    assert_equal(decoded.segment_name, "segment-delta-5.bin")
    assert_equal(decoded.segment_checksum, UInt32(0x22222222))


def test_manifest_v3_round_trips_optional_hnsw_reference() raises:
    var manifest = Manifest.with_hnsw(
        3,
        7,
        5,
        _v3_segments(),
        "hnsw-7.bin",
        UInt32(0xA1B2C3D4),
        UInt64(0x1122334455667788),
        UInt64(2),
    )
    var first = encode_manifest_v3(manifest)
    var second = encode_manifest_v3(manifest)
    var decoded = decode_manifest_bytes(first.copy(), 3)

    assert_equal(first, second)
    assert_equal(decoded.format_version, 3)
    assert_equal(len(decoded.segments), 2)
    assert_equal(decoded.segments[1].sparse_name, "sparse-delta-5.bin")
    assert_equal(decoded.hnsw_name.value(), "hnsw-7.bin")
    assert_equal(decoded.hnsw_checksum.value(), UInt32(0xA1B2C3D4))
    assert_equal(
        decoded.hnsw_config_fingerprint.value(),
        UInt64(0x1122334455667788),
    )
    assert_equal(decoded.hnsw_point_count.value(), UInt64(2))


def test_manifest_v3_without_hnsw_round_trips_but_normal_publish_stays_v2() raises:
    var manifest = Manifest.with_segments(3, 7, 5, _v3_segments())
    var v3_bytes = encode_manifest_v3(manifest)
    var decoded = decode_manifest_bytes(v3_bytes^, 3)

    assert_equal(decoded.format_version, 3)
    assert_equal(Bool(decoded.hnsw_name), False)
    assert_equal(Bool(decoded.hnsw_checksum), False)
    assert_equal(Bool(decoded.hnsw_config_fingerprint), False)
    assert_equal(Bool(decoded.hnsw_point_count), False)

    var directory = String("/tmp/akasha-manifest-v3-version-policy")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    var empty = List[UInt8]()
    write_file_sync(directory + "/segment-base-3.bin", empty)
    write_file_sync(directory + "/segment-delta-5.bin", empty)
    write_file_sync(directory + "/sparse-delta-5.bin", empty)
    publish_manifest(directory, manifest)
    var published = load_manifest(directory, 3)
    assert_equal(published.format_version, 2)

    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/segment-base-3.bin")
    remove_file_if_exists(directory + "/segment-delta-5.bin")
    remove_file_if_exists(directory + "/sparse-delta-5.bin")


def test_manifest_v3_validates_hnsw_filename_and_does_not_require_sidecar_on_load() raises:
    with assert_raises():
        _ = Manifest.with_hnsw(3, 7, 5, _v3_segments(), "", 1, 2, 3)
    with assert_raises():
        _ = Manifest.with_hnsw(
            3, 7, 5, _v3_segments(), "nested/hnsw.bin", 1, 2, 3
        )
    with assert_raises():
        _ = Manifest.with_hnsw(
            3, 7, 5, _v3_segments(), String("hnsw\0.bin"), 1, 2, 3
        )
    with assert_raises():
        _ = Manifest.with_hnsw(3, 7, 5, _v3_segments(), ".", 1, 2, 3)
    with assert_raises():
        _ = Manifest.with_hnsw(3, 7, 5, _v3_segments(), "..", 1, 2, 3)
    with assert_raises():
        _ = Manifest.with_hnsw(
            3, 7, 5, _v3_segments(), "segment-base-3.bin", 1, 2, 3
        )
    var partial = Manifest.with_segments(3, 7, 5, _v3_segments())
    partial.hnsw_checksum = Optional(UInt32(1))
    with assert_raises():
        _ = encode_manifest_v3(partial)

    var directory = String("/tmp/akasha-manifest-v3-derived-sidecar")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/hnsw-7.bin")
    var empty = List[UInt8]()
    write_file_sync(directory + "/segment-base-3.bin", empty)
    write_file_sync(directory + "/segment-delta-5.bin", empty)
    write_file_sync(directory + "/sparse-delta-5.bin", empty)
    var manifest = Manifest.with_hnsw(
        3, 7, 5, _v3_segments(), "hnsw-7.bin", 11, 22, 2
    )
    publish_manifest(directory, manifest)
    var loaded = load_manifest(directory, 3)
    assert_equal(loaded.format_version, 3)
    assert_equal(loaded.hnsw_name.value(), "hnsw-7.bin")
    assert_equal(path_exists(directory + "/hnsw-7.bin"), False)

    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/segment-base-3.bin")
    remove_file_if_exists(directory + "/segment-delta-5.bin")
    remove_file_if_exists(directory + "/sparse-delta-5.bin")


def test_manifest_v3_rejects_corruption_of_each_hnsw_field() raises:
    var manifest = Manifest.with_hnsw(
        3,
        7,
        5,
        _v3_segments(),
        "hnsw-7.bin",
        UInt32(0xA1B2C3D4),
        UInt64(0x1122334455667788),
        UInt64(2),
    )
    var encoded = encode_manifest_v3(manifest)
    var hnsw_base = len(encoded) - 4 - "hnsw-7.bin".byte_length() - 24

    var checksum_corrupt = encoded.copy()
    checksum_corrupt[hnsw_base] ^= UInt8(1)
    with assert_raises():
        _ = decode_manifest_bytes(checksum_corrupt^, 3)

    var length_corrupt = encoded.copy()
    length_corrupt[hnsw_base + 4] ^= UInt8(1)
    var length_checksum = crc32_range(
        length_corrupt, 4, len(length_corrupt) - 4
    )
    for byte_index in range(4):
        length_corrupt[len(length_corrupt) - 4 + byte_index] = UInt8(
            length_checksum >> UInt32(byte_index * 8)
        )
    with assert_raises():
        _ = decode_manifest_bytes(length_corrupt^, 3)

    var fingerprint_corrupt = encoded.copy()
    fingerprint_corrupt[hnsw_base + 8] ^= UInt8(1)
    with assert_raises():
        _ = decode_manifest_bytes(fingerprint_corrupt^, 3)

    var count_corrupt = encoded.copy()
    count_corrupt[hnsw_base + 16] ^= UInt8(1)
    with assert_raises():
        _ = decode_manifest_bytes(count_corrupt^, 3)


def test_manifest_v2_rejects_invalid_descriptors_and_duplicates() raises:
    with assert_raises():
        _ = SegmentDescriptor(-1, 1, 2, 1, "segment-negative.bin")
    with assert_raises():
        _ = SegmentDescriptor(8, 1, 2, 1, "segment-high.bin")
    with assert_raises():
        _ = SegmentDescriptor(0, 3, 2, 1, "segment-range.bin")
    with assert_raises():
        _ = SegmentDescriptor(0, 1, 2, 1, "nested/segment.bin")

    var duplicate = List[SegmentDescriptor]()
    duplicate.append(SegmentDescriptor(1, 0, 2, 1, "segment-same.bin"))
    duplicate.append(SegmentDescriptor(0, 3, 4, 2, "segment-same.bin"))
    with assert_raises():
        _ = Manifest.with_segments(1, 1, 4, duplicate^)

    var beyond_checkpoint = List[SegmentDescriptor]()
    beyond_checkpoint.append(
        SegmentDescriptor(0, 4, 6, 1, "segment-future.bin")
    )
    with assert_raises():
        _ = Manifest.with_segments(1, 1, 5, beyond_checkpoint^)


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


def test_load_v2_requires_every_referenced_segment() raises:
    var directory = String("/tmp/akasha-phase10-manifest-multi")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/segment-base-2.bin")
    remove_file_if_exists(directory + "/segment-delta-3.bin")
    remove_file_if_exists(directory + "/sparse-delta-3.bin")
    var empty = List[UInt8]()
    write_file_sync(directory + "/segment-base-2.bin", empty)
    var segments = List[SegmentDescriptor]()
    segments.append(SegmentDescriptor(1, 0, 2, 1, "segment-base-2.bin"))
    segments.append(
        SegmentDescriptor.with_sparse(
            0,
            3,
            3,
            2,
            "segment-delta-3.bin",
            3,
            "sparse-delta-3.bin",
        )
    )
    var manifest = Manifest.with_segments(1, 2, 3, segments^)
    publish_manifest(directory, manifest)

    with assert_raises():
        _ = load_manifest(directory, 1)

    write_file_sync(directory + "/segment-delta-3.bin", empty)
    with assert_raises():
        _ = load_manifest(directory, 1)

    write_file_sync(directory + "/sparse-delta-3.bin", empty)
    var loaded = load_manifest(directory, 1)
    assert_equal(len(loaded.segments), 2)

    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/segment-base-2.bin")
    remove_file_if_exists(directory + "/segment-delta-3.bin")
    remove_file_if_exists(directory + "/sparse-delta-3.bin")


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
