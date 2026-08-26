from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
)
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.checksum import BinaryWriter
from akasha.storage.index_cache import (
    CACHE_HNSW_KIND,
    CacheArtifact,
    decode_cache_bytes,
    publish_cache,
)
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def _reset(path: String) raises:
    ensure_directory(path)
    for name in [
        "manifest.bin",
        "manifest.bin.tmp",
        "wal.bin",
        "wal.bin.tmp",
        "sparse.wal",
        "sparse.wal.tmp",
        "hnsw.cache",
        "hnsw.cache.tmp",
        "metadata.cache",
        "metadata.cache.tmp",
    ]:
        remove_file_if_exists(path + "/" + name)
    for sequence in range(128):
        remove_file_if_exists(
            path + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            path + "/segment-delta-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            path + "/sparse-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            path + "/sparse-delta-" + String(sequence) + ".bin"
        )


def _expression() raises -> FilterExpression:
    return FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )


def _legacy_two_point_hnsw_payload() -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_u16(UInt16(2))
    writer.write_u16(UInt16(4))
    writer.write_u32(UInt32(2))
    writer.write_i64(Int64(0))
    writer.write_i64(Int64(1))
    writer.write_i64(Int64(10))
    writer.write_u16(UInt16(1))
    writer.write_u16(UInt16(0))
    writer.write_f32(1.0)
    writer.write_u16(UInt16(1))
    writer.write_u16(UInt16(0))
    writer.write_u32(UInt32(1))
    writer.write_u16(UInt16(0))
    writer.write_u16(UInt16(0))
    writer.write_i64(Int64(20))
    writer.write_u16(UInt16(0))
    writer.write_u16(UInt16(0))
    writer.write_f32(2.0)
    writer.write_u16(UInt16(1))
    writer.write_u16(UInt16(0))
    writer.write_u32(UInt32(0))
    return writer.take_bytes()


def test_reopen_hits_persisted_hnsw_and_metadata_caches() raises:
    var path = String("/tmp/akasha-phase12-persisted-cache")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    for id in range(1, 81):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField("keep", PayloadValue.boolean(id % 2 == 0))
        )
        collection.upsert_document(
            id, [Float32(id), Float32(id % 7) + 1.0], fields^
        )
    # Task 13 binds the compatibility HNSW graph to L2. Cross-metric
    # collection fallback remains a Task 17 integration concern.
    var expected = collection.search_l2_approx([1.0, 2.0], 3, 80)
    collection.flush()
    assert_true(path_exists(path + "/hnsw.cache"))
    assert_true(path_exists(path + "/metadata.cache"))
    collection.close()

    var reopened = PersistentCollection.open(path, 2)
    assert_true(reopened.hnsw_cache_hit())
    assert_true(reopened.metadata_cache_hit())
    var actual = reopened.search_l2_approx([1.0, 2.0], 3, 80)
    for index in range(3):
        assert_equal(actual[index].id, expected[index].id)
    var filtered = reopened.search_dot_where(
        [1.0, 0.0], 2, _expression()
    )
    assert_equal(filtered[0].id, 80)
    assert_equal(filtered[1].id, 78)
    reopened.close()


def test_corrupt_or_stale_caches_rebuild_without_losing_queries() raises:
    var path = String("/tmp/akasha-phase12-persisted-cache")
    write_file_sync(path + "/hnsw.cache", [UInt8(0), UInt8(1)])
    write_file_sync(path + "/metadata.cache", [UInt8(0), UInt8(1)])
    var reopened = PersistentCollection.open(path, 2)
    assert_false(reopened.hnsw_cache_hit())
    assert_false(reopened.metadata_cache_hit())
    assert_equal(
        reopened.search_l2_approx([1.0, 2.0], 1, 80)[0].id, 1
    )
    assert_equal(
        reopened.search_dot_where([1.0, 0.0], 1, _expression())[0].id,
        80,
    )
    assert_true(path_exists(path + "/hnsw.cache"))
    assert_true(path_exists(path + "/metadata.cache"))
    reopened.upsert(81, [100.0, 1.0])
    reopened.close()

    var stale = PersistentCollection.open(path, 2)
    assert_false(stale.hnsw_cache_hit())
    assert_false(stale.metadata_cache_hit())
    assert_equal(stale.search_dot([1.0, 0.0], 1)[0].id, 81)
    stale.close()


def test_reopen_accepts_prototype_hnsw_payload_bytes() raises:
    var path = String("/tmp/akasha-phase13-legacy-hnsw-cache")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(10, [1.0])
    collection.upsert(20, [2.0])
    _ = collection.search_l2_approx([1.1], 1, 8)
    collection.flush()
    collection.close()

    var current = decode_cache_bytes(
        read_file_bytes(path + "/hnsw.cache")
    )
    var legacy = _legacy_two_point_hnsw_payload()
    var artifact = CacheArtifact(
        CACHE_HNSW_KIND,
        1,
        current.generation,
        current.sequence,
        current.source_checksum,
        legacy^,
    )
    publish_cache(path, "hnsw.cache", artifact)

    var reopened = PersistentCollection.open(path, 1)
    assert_true(reopened.hnsw_cache_hit())
    assert_equal(reopened.search_l2_approx([1.1], 1, 8)[0].id, 10)
    reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
