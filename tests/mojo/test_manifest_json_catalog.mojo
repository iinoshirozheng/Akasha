from akasha.storage.manifest import Manifest, encode_manifest_v6, encode_manifest_v5, encode_manifest_v2, decode_manifest_bytes, publish_manifest, read_manifest_bytes, hnsw_base_sequence
from akasha.index.json_catalog import JsonIndexDefinition
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import read_file_bytes
from test_manifest import _v3_segments
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite


def test_v6_catalog_roundtrip_hnsw_and_publication() raises:
    for hnsw in range(2):
        var manifest = Manifest.with_segments(3, 7, 5, _v3_segments()) if hnsw == 0 else Manifest.with_hnsw(3, 7, 5, _v3_segments(), "hnsw-3-2-1.bin", 11, 22, 2, format_version=6)
        manifest.format_version = 6
        manifest.json_catalog.revision = 1
        manifest.json_catalog.definitions.append(JsonIndexDefinition("price", "data", "$.price", 3))
        var bytes = encode_manifest_v6(manifest)
        var decoded = decode_manifest_bytes(bytes.copy(), 3)
        assert_equal(decoded.format_version, 6)
        assert_equal(decoded.json_catalog.revision, UInt64(1))
        assert_equal(decoded.json_catalog.definitions[0].path, "$.price")
        assert_equal(encode_manifest_v6(decoded), bytes)
        if hnsw != 0:
            assert_equal(hnsw_base_sequence(decoded), UInt64(3))
        with assert_raises():
            _ = encode_manifest_v5(manifest)
        with assert_raises():
            _ = encode_manifest_v2(manifest)
        var directory = Python.import_module("tempfile").TemporaryDirectory()
        publish_manifest(String(py=directory.name), manifest)
        var loaded = decode_manifest_bytes(read_manifest_bytes(String(py=directory.name)), 3)
        assert_equal(loaded.json_catalog.revision, UInt64(1))
        directory.cleanup()
        for length in range(len(bytes)):
            var truncated = List[UInt8]()
            truncated.extend(Span(bytes)[:length])
            with assert_raises():
                _ = decode_manifest_bytes(truncated^, 3)
        bytes[len(bytes)-5] ^= 1
        with assert_raises():
            _ = decode_manifest_bytes(bytes^, 3)


def test_legacy_catalog_defaults_and_valid_crc_bad_section() raises:
    var legacy = Manifest.with_segments(3, 7, 5, _v3_segments())
    var bytes = encode_manifest_v2(legacy)
    assert_equal(decode_manifest_bytes(bytes^, 3).json_catalog.revision, UInt64(0))
    legacy.format_version = 6
    var encoded = encode_manifest_v6(legacy)
    # Empty section has 12 bytes; corrupt its version, then recompute outer CRC.
    encoded[len(encoded)-16] = 255
    var checksum = crc32_range(encoded, 4, len(encoded)-4)
    for i in range(4):
        encoded[len(encoded)-4+i] = UInt8((checksum >> UInt32(i*8)) & 255)
    with assert_raises():
        _ = decode_manifest_bytes(encoded^, 3)


def test_frozen_independently_encoded_v6_fixture() raises:
    var bytes = read_file_bytes("tests/fixtures/manifest-v6-json-catalog.bin")
    var manifest = decode_manifest_bytes(bytes.copy(), 1)
    assert_equal(manifest.generation, UInt64(2))
    assert_equal(manifest.last_sequence, UInt64(1))
    assert_equal(manifest.segments[0].name, "segment-1.bin")
    assert_equal(manifest.json_catalog.revision, UInt64(1))
    assert_equal(manifest.json_catalog.definitions[0].name, "v")
    assert_equal(manifest.json_catalog.definitions[0].column, "data")
    assert_equal(manifest.json_catalog.definitions[0].path, "$.v")
    assert_equal(manifest.json_catalog.definitions[0].target, UInt8(2))
    assert_equal(encode_manifest_v6(manifest), bytes)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
