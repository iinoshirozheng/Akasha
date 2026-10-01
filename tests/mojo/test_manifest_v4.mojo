from akasha.storage.filesystem import read_file_bytes
from akasha.storage.checksum import crc32_range
from akasha.storage.manifest import (
    decode_manifest_bytes,
    encode_manifest_v3,
    encode_manifest_v4,
    Manifest,
    parse_hnsw_job_name,
    SegmentDescriptor,
)
from std.testing import assert_equal, assert_false, assert_raises, TestSuite


def _fixture() raises -> List[UInt8]:
    return read_file_bytes("tests/fixtures/manifest-v4-hnsw.bin")


def _manifest(name: String) raises -> Manifest:
    var segments = List[SegmentDescriptor]()
    segments.append(
        SegmentDescriptor(1, 0, 5, 0x11223344, "segment-base-5.bin")
    )
    return Manifest.with_hnsw(
        3,
        7,
        5,
        segments^,
        name,
        0xA1B2C3D4,
        0x1122334455667788,
        2,
        format_version=4,
    )


def _rechecksum(mut bytes: List[UInt8]):
    var crc = crc32_range(bytes, 4, len(bytes) - 4)
    for i in range(4):
        bytes[len(bytes) - 4 + i] = UInt8(crc >> UInt32(i * 8))


def test_v4_reads_independent_job_name_fixture() raises:
    var decoded = decode_manifest_bytes(_fixture(), 3)
    assert_equal(decoded.format_version, 4)
    assert_equal(decoded.generation, UInt64(7))
    assert_equal(decoded.last_sequence, UInt64(5))
    assert_equal(decoded.hnsw_name.value(), "hnsw-5-6-2.bin")
    assert_equal(decoded.hnsw_checksum.value(), UInt32(0xA1B2C3D4))
    assert_equal(
        decoded.hnsw_config_fingerprint.value(), UInt64(0x1122334455667788)
    )
    assert_equal(decoded.hnsw_point_count.value(), UInt64(2))
    assert_equal(decoded.segments[0].name, "segment-base-5.bin")


def test_v4_encoder_matches_independent_bytes_and_preserves_carry_forward() raises:
    var manifest = _manifest("hnsw-5-6-2.bin")
    assert_equal(encode_manifest_v4(manifest), _fixture())
    var decoded = decode_manifest_bytes(_fixture(), 3)
    assert_equal(encode_manifest_v4(decoded), _fixture())
    decoded.generation = 8
    var carried = decode_manifest_bytes(encode_manifest_v4(decoded), 3)
    assert_equal(carried.hnsw_name.value(), "hnsw-5-6-2.bin")
    assert_equal(carried.generation, UInt64(8))


def test_v4_rejects_unsafe_noncanonical_or_mismatched_names() raises:
    for name in [
        "hnsw-5.bin",
        "hnsw-6-6-0.bin",
        "hnsw-5-0-0.bin",
        "hnsw-5-8-0.bin",
        "hnsw-05-6-0.bin",
        "hnsw-5-06-0.bin",
        "hnsw-5-6-00.bin",
        "hnsw-5-6-+1.bin",
        "hnsw-5-6--1.bin",
        "hnsw-5-6- 1.bin",
        "hnsw-5-6-18446744073709551616.bin",
        "hnsw-5-6-0.bin.tmp",
        "../hnsw-5-6-0.bin",
        "hnsw-5-6-0.bin/other",
        "manifest.bin",
    ]:
        with assert_raises():
            _ = _manifest(name)
    var boundary = parse_hnsw_job_name(
        "hnsw-18446744073709551615-18446744073709551615-18446744073709551615.bin"
    )
    assert_equal(boundary[0], UInt64.MAX)
    assert_equal(boundary[1], UInt64.MAX)
    assert_equal(boundary[2], UInt64.MAX)


def test_v3_never_silently_accepts_job_names() raises:
    var manifest = _manifest("hnsw-5-6-2.bin")
    with assert_raises():
        _ = encode_manifest_v3(manifest)
    var encoded = _fixture()
    encoded[4] = 3
    _rechecksum(encoded)
    with assert_raises():
        _ = decode_manifest_bytes(encoded^, 3)


def test_v4_rejects_torn_corrupt_unknown_flags_and_future_versions() raises:
    var full = _fixture()
    for size in range(len(full)):
        var torn = List[UInt8]()
        for i in range(size):
            torn.append(full[i])
        with assert_raises():
            _ = decode_manifest_bytes(torn^, 3)
    for offset in [4, 6, 12, 20, 32, 88, 113]:
        var changed = full.copy()
        changed[offset] = 9
        _rechecksum(changed)
        # A larger manifest generation is valid; creation generation may lag.
        if offset == 12:
            assert_equal(
                decode_manifest_bytes(changed^, 3).generation, UInt64(9)
            )
        else:
            with assert_raises():
                _ = decode_manifest_bytes(changed^, 3)
    var bad_crc = full.copy()
    bad_crc[len(bad_crc) - 1] ^= 1
    with assert_raises():
        _ = decode_manifest_bytes(bad_crc^, 3)


def test_v4_without_derived_reference_keeps_strict_names() raises:
    var segments = List[SegmentDescriptor]()
    segments.append(SegmentDescriptor(1, 0, 5, 1, "segment-base-5.bin"))
    var manifest = Manifest.with_segments(3, 7, 5, segments^)
    manifest.format_version = 4
    var decoded = decode_manifest_bytes(encode_manifest_v4(manifest), 3)
    assert_equal(decoded.format_version, 4)
    assert_false(Bool(decoded.hnsw_name))
    manifest.segments[0].name = ".."
    with assert_raises():
        _ = encode_manifest_v4(manifest)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
