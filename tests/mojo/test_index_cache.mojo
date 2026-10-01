from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.index_cache import (
    authoritative_index_checksum,
    CACHE_HNSW_KIND,
    CACHE_METADATA_KIND,
    CacheArtifact,
    decode_cache_bytes,
    encode_cache,
    load_cache_payload,
    publish_cache,
)
from akasha.document import DocumentField, PayloadValue
from akasha.index.sparse import SparseElement
from akasha.storage.memtable import MemTable
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


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
    var taken = decoded.take_payload()
    assert_equal(taken, [UInt8(1), UInt8(2), UInt8(3)])
    assert_equal(len(decoded.payload), 0)
    assert_equal(decoded.generation, UInt64(4))


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


def test_authoritative_fingerprint_preserves_frozen_state_bytes() raises:
    # Independently encoded with Python struct + zlib. Stable insertion order,
    # signed IDs/zeros, all payload kinds and tombstones belong to the contract.
    var table = MemTable(2)
    assert_equal(authoritative_index_checksum(table), UInt32(0x2707D814))
    var fields: List[DocumentField] = [
        DocumentField("tag", PayloadValue.string("長長長")),
        DocumentField("n", PayloadValue.integer(Int64.MIN)),
        DocumentField("f", PayloadValue.floating(-0.0)),
        DocumentField("b", PayloadValue.boolean(True)),
    ]
    table.apply_document_upsert(-7, 1, [-0.0, 1.5], fields^)
    table.apply_upsert(Int.MIN, 2, [2.0, -3.0])
    table.apply_upsert(42, 3, [4.0, 5.0])
    assert_equal(authoritative_index_checksum(table), UInt32(0xFFE4398B))
    var replaced: List[DocumentField] = [
        DocumentField("b", PayloadValue.boolean(False))
    ]
    table.apply_document_upsert(42, 4, [9.0, -7.0], replaced^)
    assert_equal(authoritative_index_checksum(table), UInt32(0x5DA4F081))
    table.apply_delete(-7, 5)
    assert_equal(authoritative_index_checksum(table), UInt32(0x29833024))
    table.apply_delete(-100, 6)
    assert_equal(authoritative_index_checksum(table), UInt32(0x8EB737A2))
    var fresh: List[DocumentField] = [
        DocumentField("n", PayloadValue.integer(Int64.MAX))
    ]
    table.apply_document_upsert(-7, 7, [8.25, -0.0], fresh^)
    assert_equal(authoritative_index_checksum(table), UInt32(0x8F88903A))
    table.set_sparse(-7, [SparseElement(17, 1.5)])
    assert_equal(authoritative_index_checksum(table), UInt32(0x8F88903A))
    assert_equal(table.last_sequence, UInt64(7))
    assert_equal(table.live_count(), 3)


def test_oversized_cache_is_rejected_before_materialization() raises:
    from std.python import Python

    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-cache-bound-"
        )
    )
    var file = Python.import_module("builtins").open(
        path + "/oversized.cache", "wb"
    )
    _ = file.truncate(512 * 1024 * 1024 + 41)
    file.close()
    assert_false(
        Bool(
            load_cache_payload(
                path + "/oversized.cache",
                CACHE_METADATA_KIND,
                1,
                0,
                0,
                0,
            )
        )
    )
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
