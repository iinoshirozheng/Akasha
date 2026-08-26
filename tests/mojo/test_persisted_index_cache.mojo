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
    remove_file_if_exists,
    write_file_sync,
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
    var expected = collection.search_dot_approx([1.0, 0.0], 3, 80)
    collection.flush()
    assert_true(path_exists(path + "/hnsw.cache"))
    assert_true(path_exists(path + "/metadata.cache"))
    collection.close()

    var reopened = PersistentCollection.open(path, 2)
    assert_true(reopened.hnsw_cache_hit())
    assert_true(reopened.metadata_cache_hit())
    var actual = reopened.search_dot_approx([1.0, 0.0], 3, 80)
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
        reopened.search_dot_approx([1.0, 0.0], 1, 80)[0].id, 80
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
