from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    remove_file_if_exists,
)
from akasha.storage.index_cache import (
    CacheArtifact,
    CACHE_HNSW_KIND,
    CACHE_METADATA_KIND,
    CACHE_HNSW_OVERLAY_KIND,
    decode_cache_bytes,
    encode_cache,
    publish_cache,
)
from akasha.storage.mapped_file import MappedFile
from std.testing import assert_equal, assert_raises, TestSuite


def test_published_envelope_matches_frozen_independent_bytes() raises:
    var directory = String("/tmp/akasha-cache-publication-frozen")
    ensure_directory(directory)
    # Python struct.pack + zlib.crc32, independent of the encoder.
    var frozen: List[UInt8] = [
        65,
        75,
        73,
        67,
        1,
        0,
        3,
        0,
        0,
        6,
        0,
        0,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        255,
        19,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        120,
        86,
        52,
        18,
        6,
        0,
        0,
        0,
        0,
        255,
        4,
        0,
        128,
        42,
        92,
        179,
        239,
        131,
    ]
    var artifact = decode_cache_bytes(frozen.copy())
    publish_cache(directory, "hnsw.cache", artifact)
    assert_equal(read_file_bytes(directory + "/hnsw.cache"), frozen)
    remove_file_if_exists(directory + "/hnsw.cache")


def test_published_envelope_matches_owned_codec_for_all_kinds_and_sizes() raises:
    var directory = String("/tmp/akasha-cache-publication-kinds")
    ensure_directory(directory)
    for kind in [CACHE_HNSW_KIND, CACHE_METADATA_KIND, CACHE_HNSW_OVERLAY_KIND]:
        for size in [0, 1, 24, 28, 4097, 65536]:
            var payload = List[UInt8](capacity=size)
            for i in range(size):
                payload.append(UInt8(i % 256))
            var artifact = CacheArtifact(
                kind, 7, UInt64.MAX, 0, UInt32.MAX, payload^
            )
            var expected = encode_cache(artifact)
            publish_cache(directory, "index.cache", artifact)
            assert_equal(read_file_bytes(directory + "/index.cache"), expected)
    remove_file_if_exists(directory + "/index.cache")


def test_publication_preserves_old_inode_and_failed_replacement() raises:
    from std.python import Python

    var shutil = Python.import_module("shutil")
    var directory = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-cache-publication-"
        )
    )
    var path = directory + "/index.cache"
    var first = CacheArtifact(
        CACHE_HNSW_KIND, 2, 1, 2, 3, [UInt8(1), UInt8(2), UInt8(3)]
    )
    var second = CacheArtifact(
        CACHE_HNSW_KIND, 2, 4, 5, 6, [UInt8(9), UInt8(8), UInt8(7)]
    )
    publish_cache(directory, "index.cache", first)
    var old_mapping = MappedFile.open_readonly(path)
    publish_cache(directory, "index.cache", second)
    assert_equal(old_mapping.byte_at(36), UInt8(1))
    assert_equal(old_mapping.byte_at(38), UInt8(3))
    assert_equal(read_file_bytes(path), encode_cache(second))
    # An unwritable temporary pathname cannot truncate the published inode.
    ensure_directory(path + ".tmp")
    with assert_raises():
        publish_cache(directory, "index.cache", first)
    assert_equal(read_file_bytes(path), encode_cache(second))
    assert_equal(old_mapping.byte_at(36), UInt8(1))
    shutil.rmtree(directory)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
