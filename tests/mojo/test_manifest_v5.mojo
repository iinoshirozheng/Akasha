from akasha.storage.filesystem import read_file_bytes
from akasha.storage.checksum import crc32_range
from akasha.storage.manifest import (
    Manifest,
    SegmentDescriptor,
    decode_manifest_bytes,
    encode_manifest_v4,
    encode_manifest_v5,
    hnsw_base_sequence,
)
from std.testing import assert_equal, assert_raises, TestSuite


def _fixture() raises -> List[UInt8]:
    return read_file_bytes("tests/fixtures/manifest-v5-hnsw-base.bin")


def _manifest(name: String) raises -> Manifest:
    return Manifest.with_hnsw(
        3,
        7,
        5,
        [SegmentDescriptor(1, 0, 5, 0x11223344, "segment-base-5.bin")],
        name,
        0xA1B2C3D4,
        0x1122334455667788,
        2,
        format_version=5,
    )


def _crc(mut bytes: List[UInt8]):
    var crc = crc32_range(bytes, 4, len(bytes) - 4)
    for i in range(4):
        bytes[len(bytes) - 4 + i] = UInt8(crc >> UInt32(i * 8))


def test_v5_independent_fixture_retains_older_base_identity() raises:
    var fixture = _fixture()
    var decoded = decode_manifest_bytes(fixture.copy(), 3)
    assert_equal(decoded.format_version, 5)
    assert_equal(decoded.last_sequence, UInt64(5))
    assert_equal(hnsw_base_sequence(decoded), UInt64(3))
    assert_equal(decoded.hnsw_point_count.value(), UInt64(2))
    assert_equal(encode_manifest_v5(decoded), fixture)
    assert_equal(encode_manifest_v5(_manifest("hnsw-3-6-2.bin")), fixture)
    decoded.generation = 8
    decoded.last_sequence = 6
    decoded.segments[0].max_sequence = 6
    assert_equal(
        hnsw_base_sequence(
            decode_manifest_bytes(encode_manifest_v5(decoded), 3)
        ),
        UInt64(3),
    )


def test_v5_does_not_relax_v4_or_accept_future_base() raises:
    with assert_raises():
        _ = encode_manifest_v4(_manifest("hnsw-3-6-2.bin"))
    for name in [
        "hnsw-6-6-0.bin",
        "hnsw-3-8-0.bin",
        "hnsw-03-6-0.bin",
        "hnsw-3.bin",
        "../hnsw-3-6-0.bin",
    ]:
        with assert_raises():
            _ = _manifest(name)
    var old = _fixture()
    old[4] = 4
    _crc(old)
    with assert_raises():
        _ = decode_manifest_bytes(old^, 3)


def test_v5_rejects_torn_crc_flags_and_unknown_version() raises:
    var full = _fixture()
    for size in range(len(full)):
        var prefix = List[UInt8]()
        prefix.extend(Span(full)[:size])
        with assert_raises():
            _ = decode_manifest_bytes(prefix^, 3)
    for offset in [4, 6, 32]:
        var bad = full.copy()
        bad[offset] = 99
        _crc(bad)
        with assert_raises():
            _ = decode_manifest_bytes(bad^, 3)
    full[len(full) - 1] ^= 1
    with assert_raises():
        _ = decode_manifest_bytes(full^, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
