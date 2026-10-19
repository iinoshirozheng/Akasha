from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import (
    ensure_directory,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.index_cache import (
    CACHE_HNSW_KIND,
    CACHE_HNSW_OVERLAY_KIND,
    CACHE_METADATA_KIND,
    CacheArtifact,
    decode_cache_bytes,
    encode_cache,
    load_cache_artifact,
)
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _frozen() -> List[UInt8]:
    # Independently encoded by Python struct.pack + zlib.crc32 (AKIC v1).
    return [
        UInt8(65),
        UInt8(75),
        UInt8(73),
        UInt8(67),
        UInt8(1),
        UInt8(0),
        UInt8(3),
        UInt8(0),
        UInt8(0),
        UInt8(6),
        UInt8(0),
        UInt8(0),
        UInt8(255),
        UInt8(255),
        UInt8(255),
        UInt8(255),
        UInt8(255),
        UInt8(255),
        UInt8(255),
        UInt8(255),
        UInt8(19),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(120),
        UInt8(86),
        UInt8(52),
        UInt8(18),
        UInt8(6),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(0),
        UInt8(255),
        UInt8(4),
        UInt8(0),
        UInt8(128),
        UInt8(42),
        UInt8(92),
        UInt8(179),
        UInt8(239),
        UInt8(131),
    ]


def _rechecksum(mut bytes: List[UInt8]) raises:
    var checksum = crc32_range(bytes, 0, len(bytes) - 4)
    for i in range(4):
        bytes[len(bytes) - 4 + i] = UInt8(checksum >> UInt32(8 * i))


def _reject(bytes: List[UInt8], path: String) raises:
    with assert_raises():
        _ = decode_cache_bytes(bytes.copy())
    write_file_sync(path, bytes)
    assert_false(Bool(load_cache_artifact(path)))


def test_mapped_cache_retains_old_inode_after_file_replacement() raises:
    var path = String("/tmp/akasha-cache-mapped-frozen.cache")
    var bytes = _frozen()
    write_file_sync(path, bytes)
    var loaded = load_cache_artifact(path)
    assert_true(Bool(loaded))
    var mapped = loaded.take()
    var owned = decode_cache_bytes(bytes^)
    remove_file_if_exists(path)
    write_file_sync(path, [UInt8(9)])
    assert_equal(mapped.version, UInt16(1))
    assert_equal(mapped.kind, CACHE_HNSW_OVERLAY_KIND)
    assert_equal(mapped.dimension, 1536)
    assert_equal(mapped.generation, UInt64.MAX)
    assert_equal(mapped.sequence, UInt64(19))
    assert_equal(mapped.source_checksum, UInt32(0x12345678))
    var reader = mapped.payload_reader()
    var payload = reader.read_bytes(mapped.payload_length)
    assert_equal(payload, owned.payload)
    assert_equal(
        payload,
        [UInt8(0), UInt8(255), UInt8(4), UInt8(0), UInt8(128), UInt8(42)],
    )
    assert_equal(reader.remaining(), 0)
    with assert_raises():
        _ = reader.read_u8()
    mapped._mapping.close()
    assert_equal(payload[5], UInt8(42))
    remove_file_if_exists(path)


def test_mapped_cache_round_trips_all_kinds_and_empty_payload() raises:
    var path = String("/tmp/akasha-cache-mapped-kinds.cache")
    for kind in [CACHE_HNSW_KIND, CACHE_METADATA_KIND, CACHE_HNSW_OVERLAY_KIND]:
        for size in [0, 1, 4097]:
            var payload = List[UInt8](capacity=size)
            for i in range(size):
                payload.append(UInt8(i % 256))
            var artifact = CacheArtifact(
                kind, 1, 0, UInt64.MAX, UInt32.MAX, payload^
            )
            var bytes = encode_cache(artifact)
            write_file_sync(path, bytes)
            var loaded = load_cache_artifact(path)
            assert_true(Bool(loaded))
            var mapped = loaded.take()
            assert_equal(mapped.kind, kind)
            assert_equal(mapped.dimension, 1)
            assert_equal(mapped.generation, UInt64(0))
            assert_equal(mapped.sequence, UInt64.MAX)
            assert_equal(mapped.source_checksum, UInt32.MAX)
            var reader = mapped.payload_reader()
            assert_equal(reader.read_bytes(size), artifact.payload)
            assert_equal(reader.remaining(), 0)
    remove_file_if_exists(path)


def test_mapped_and_owned_cache_reject_every_truncation_and_byte_flip() raises:
    var path = String("/tmp/akasha-cache-mapped-corruption.cache")
    var bytes = _frozen()
    for length in range(len(bytes)):
        var prefix = List[UInt8](capacity=length)
        for i in range(length):
            prefix.append(bytes[i])
        _reject(prefix, path)
    for i in range(len(bytes)):
        var corrupt = bytes.copy()
        corrupt[i] ^= UInt8(1)
        _reject(corrupt, path)
    remove_file_if_exists(path)


def test_mapped_and_owned_cache_validate_crc_correct_headers() raises:
    var path = String("/tmp/akasha-cache-mapped-header.cache")
    var bytes = _frozen()
    for scenario in range(8):
        var bad = bytes.copy()
        if scenario == 0:
            bad[0] = UInt8(0)  # Magic.
        elif scenario == 1:
            bad[4] = UInt8(2)  # Unknown version.
        elif scenario == 2:
            bad[6] = UInt8(4)  # Unknown kind.
        elif scenario == 3:
            bad[7] = UInt8(1)  # Reserved byte.
        elif scenario == 4:
            for i in range(8, 12):
                bad[i] = UInt8(0)  # Zero dimension.
        elif scenario == 5:
            bad[32] = UInt8(5)  # Payload length below actual.
        elif scenario == 6:
            bad[32] = UInt8(7)  # Payload length above actual.
        else:
            for i in range(32, 36):
                bad[i] = UInt8(255)  # Declared payload exceeds bound.
        _rechecksum(bad)
        _reject(bad, path)
    remove_file_if_exists(path)


def test_mapped_optional_cache_missing_or_nonregular_is_a_miss() raises:
    var path = String("/tmp/akasha-cache-mapped-absent.cache")
    remove_file_if_exists(path)
    assert_false(Bool(load_cache_artifact(path)))
    var directory = String("/tmp/akasha-cache-mapped-directory")
    ensure_directory(directory)
    assert_false(Bool(load_cache_artifact(directory)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
