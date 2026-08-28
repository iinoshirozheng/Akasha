from akasha.storage.manifest import (
    decode_manifest_bytes,
    encode_manifest,
    encode_manifest_v2,
    Manifest,
    SegmentDescriptor,
)
from std.testing import assert_equal, TestSuite


def _manifest_v1_fixture() -> List[UInt8]:
    # Independent struct.pack/zlib fixture for one legacy snapshot manifest.
    return [
        0x41,
        0x4B,
        0x4D,
        0x46,
        0x01,
        0x00,
        0x00,
        0x00,
        0x03,
        0x00,
        0x00,
        0x00,
        0x09,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x78,
        0x56,
        0x34,
        0x12,
        0x0D,
        0x00,
        0x00,
        0x00,
        0x73,
        0x65,
        0x67,
        0x6D,
        0x65,
        0x6E,
        0x74,
        0x2D,
        0x39,
        0x2E,
        0x62,
        0x69,
        0x6E,
        0x56,
        0xE6,
        0xAB,
        0xA8,
    ]


def _manifest_v2_fixture() -> List[UInt8]:
    # Independent struct.pack/zlib fixture for dense + sparse descriptors.
    return [
        0x41,
        0x4B,
        0x4D,
        0x46,
        0x02,
        0x00,
        0x00,
        0x00,
        0x03,
        0x00,
        0x00,
        0x00,
        0x07,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x05,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x02,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x03,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x11,
        0x11,
        0x11,
        0x11,
        0x12,
        0x00,
        0x00,
        0x00,
        0x73,
        0x65,
        0x67,
        0x6D,
        0x65,
        0x6E,
        0x74,
        0x2D,
        0x62,
        0x61,
        0x73,
        0x65,
        0x2D,
        0x33,
        0x2E,
        0x62,
        0x69,
        0x6E,
        0x00,
        0x00,
        0x01,
        0x00,
        0x04,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x05,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x22,
        0x22,
        0x22,
        0x22,
        0x13,
        0x00,
        0x00,
        0x00,
        0x73,
        0x65,
        0x67,
        0x6D,
        0x65,
        0x6E,
        0x74,
        0x2D,
        0x64,
        0x65,
        0x6C,
        0x74,
        0x61,
        0x2D,
        0x35,
        0x2E,
        0x62,
        0x69,
        0x6E,
        0x33,
        0x33,
        0x33,
        0x33,
        0x12,
        0x00,
        0x00,
        0x00,
        0x73,
        0x70,
        0x61,
        0x72,
        0x73,
        0x65,
        0x2D,
        0x64,
        0x65,
        0x6C,
        0x74,
        0x61,
        0x2D,
        0x35,
        0x2E,
        0x62,
        0x69,
        0x6E,
        0x39,
        0x17,
        0x8E,
        0x68,
    ]


def test_manifest_v1_fixture_remains_readable() raises:
    var fixture = _manifest_v1_fixture()
    var decoded = decode_manifest_bytes(fixture.copy(), 3)

    assert_equal(decoded.format_version, 1)
    assert_equal(decoded.last_sequence, UInt64(9))
    assert_equal(decoded.segment_checksum, UInt32(0x12345678))
    assert_equal(decoded.segment_name, "segment-9.bin")
    assert_equal(len(decoded.segments), 1)
    assert_equal(Bool(decoded.hnsw_name), False)
    assert_equal(Bool(decoded.hnsw_checksum), False)
    assert_equal(Bool(decoded.hnsw_config_fingerprint), False)
    assert_equal(Bool(decoded.hnsw_point_count), False)
    assert_equal(encode_manifest(3, 9, 0x12345678, "segment-9.bin"), fixture)


def test_manifest_v2_fixture_retains_dense_and_sparse_descriptors() raises:
    var fixture = _manifest_v2_fixture()
    var decoded = decode_manifest_bytes(fixture.copy(), 3)

    assert_equal(decoded.format_version, 2)
    assert_equal(decoded.generation, UInt64(7))
    assert_equal(decoded.last_sequence, UInt64(5))
    assert_equal(len(decoded.segments), 2)
    assert_equal(decoded.segments[0].name, "segment-base-3.bin")
    assert_equal(decoded.segments[1].name, "segment-delta-5.bin")
    assert_equal(decoded.segments[1].sparse_checksum, UInt32(0x33333333))
    assert_equal(decoded.segments[1].sparse_name, "sparse-delta-5.bin")
    assert_equal(Bool(decoded.hnsw_name), False)
    assert_equal(Bool(decoded.hnsw_checksum), False)
    assert_equal(Bool(decoded.hnsw_config_fingerprint), False)
    assert_equal(Bool(decoded.hnsw_point_count), False)

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
    assert_equal(encode_manifest_v2(manifest), fixture)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
