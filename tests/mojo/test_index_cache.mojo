from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.index_cache import (
    CACHE_HNSW_KIND,
    CACHE_METADATA_KIND,
    CacheArtifact,
    decode_cache_bytes,
    encode_cache,
    load_cache_payload,
    publish_cache,
)
from std.testing import assert_equal, assert_false, assert_raises, assert_true, TestSuite


def test_cache_envelope_round_trips_header_and_payload() raises:
    var payload: List[UInt8] = [UInt8(1), UInt8(2), UInt8(3)]
    var artifact = CacheArtifact(
        CACHE_HNSW_KIND,
        8,
        UInt64(4),
        UInt64(19),
        UInt32(0x12345678),
        payload^,
    )
    var decoded = decode_cache_bytes(encode_cache(artifact))
    assert_equal(decoded.version, UInt16(1))
    assert_equal(decoded.kind, CACHE_HNSW_KIND)
    assert_equal(decoded.dimension, 8)
    assert_equal(decoded.generation, UInt64(4))
    assert_equal(decoded.sequence, UInt64(19))
    assert_equal(decoded.source_checksum, UInt32(0x12345678))
    assert_equal(decoded.payload[2], UInt8(3))


def test_cache_decoder_rejects_corruption_truncation_and_unknown_kind() raises:
    var payload: List[UInt8] = [UInt8(9), UInt8(8)]
    var artifact = CacheArtifact(
        CACHE_METADATA_KIND, 3, UInt64(1), UInt64(2), UInt32(7), payload^
    )
    var bytes = encode_cache(artifact)
    var corrupt = bytes.copy()
    corrupt[10] ^= UInt8(1)
    with assert_raises():
        _ = decode_cache_bytes(corrupt^)
    var truncated = bytes.copy()
    _ = truncated.pop()
    with assert_raises():
        _ = decode_cache_bytes(truncated^)
    var bad_kind = bytes.copy()
    bad_kind[6] = UInt8(99)
    with assert_raises():
        _ = decode_cache_bytes(bad_kind^)


def test_cache_publish_is_atomic_and_stale_or_bad_cache_is_a_miss() raises:
    var path = String("/tmp/akasha-phase12-cache")
    ensure_directory(path)
    remove_file_if_exists(path + "/hnsw.cache")
    remove_file_if_exists(path + "/hnsw.cache.tmp")
    var payload: List[UInt8] = [UInt8(4), UInt8(5)]
    var artifact = CacheArtifact(
        CACHE_HNSW_KIND,
        2,
        UInt64(3),
        UInt64(11),
        UInt32(77),
        payload^,
    )
    publish_cache(path, "hnsw.cache", artifact)
    assert_true(path_exists(path + "/hnsw.cache"))
    assert_false(path_exists(path + "/hnsw.cache.tmp"))
    var hit = load_cache_payload(
        path + "/hnsw.cache",
        CACHE_HNSW_KIND,
        2,
        UInt64(3),
        UInt64(11),
        UInt32(77),
    )
    assert_true(Bool(hit))
    assert_equal(hit.value()[1], UInt8(5))
    assert_false(
        Bool(
            load_cache_payload(
                path + "/hnsw.cache",
                CACHE_HNSW_KIND,
                2,
                UInt64(3),
                UInt64(12),
                UInt32(77),
            )
        )
    )
    write_file_sync(path + "/hnsw.cache", [UInt8(0), UInt8(1)])
    assert_false(
        Bool(
            load_cache_payload(
                path + "/hnsw.cache",
                CACHE_HNSW_KIND,
                2,
                UInt64(3),
                UInt64(11),
                UInt32(77),
            )
        )
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
