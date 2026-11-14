from akasha.index.lance_btree import LanceBTreeIndex
from akasha.index.lance_bitmap import LanceBitmapIndex, LanceBitmapRow, LanceBitmapQuery, LanceBitmapBound
from akasha.index.bitmap_sort import ExternalBitmapSort
from akasha.index.lance_scalar import LanceScalarKey
from akasha.storage.btree_pages import stage_btree_pages, map_btree_pages
from akasha.storage.index_cache import CacheArtifact, CACHE_JSON_BTREE_KIND, publish_cache, load_cache_artifact
from akasha.storage.index_cache import publish_mapped_cache
from akasha.storage.filesystem import remove_file_if_exists
from akasha.query.control import QueryControl, CancellationToken
from std.memory import ArcPointer
from std.python import Python
from test_lance_bitmap import _key, _query, _ids
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def _build(rows: List[LanceBitmapRow], target: UInt8, page_rows: Int = 3) raises -> LanceBTreeIndex:
    var sorter = ExternalBitmapSort(memory_bytes=512)
    for row in rows:
        sorter.push(row.copy())
    sorter.prepare(target)
    return LanceBTreeIndex(stage_btree_pages(sorter, "data", "$.v", target, True, 2, 17, 42, page_rows=page_rows))


def test_paged_search_all_types_spill_and_mapped_reopen() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var keys: List[LanceScalarKey] = [LanceScalarKey.boolean(True), LanceScalarKey.integer(-7),
        LanceScalarKey.float_bits(0x8000000000000000), LanceScalarKey.text("雪"), LanceScalarKey.binary([UInt8(0), 255])]
    for key in keys:
        var rows = List[LanceBitmapRow]()
        for i in range(131):
            rows.append(LanceBitmapRow(LanceScalarKey.null(key.target) if i % 5 == 0 else key.copy(), UInt64(i)))
        var index = _build(rows, key.target)
        var bitmap = LanceBitmapIndex.build(key.target, rows)
        assert_equal(index.pages.row_count, 131)
        assert_equal(len(index.pages.locations), 44)
        assert_equal(index.pages.artifact[]._mapping._descriptor_for_testing(), -1)
        var queries: List[LanceBitmapQuery] = [LanceBitmapQuery.equals(key.copy()),
            LanceBitmapQuery.is_null(), LanceBitmapQuery.is_in([key.copy()]),
            LanceBitmapQuery.range_of(LanceBitmapBound(Optional(key.copy())), LanceBitmapBound(Optional(key.copy())))]
        publish_mapped_cache(path, "btree.cache", index.pages.artifact[])
        var artifact = load_cache_artifact(path + "/btree.cache")
        assert_true(Bool(artifact))
        var mapped = artifact.take()
        mapped._mapping.release_descriptor()
        var reopened = LanceBTreeIndex(map_btree_pages(ArcPointer(mapped^), "data", "$.v", key.target, 131))
        remove_file_if_exists(path + "/btree.cache")
        for query in queries:
            for track in [False, True]:
                var expected = bitmap.search(query, track_nulls=track)
                var actual = reopened.search(query, track_nulls=track)
                assert_equal(actual.true_rows().values(), expected.true_rows().values())
                assert_equal(actual.nulls.values(), expected.nulls.values())
        assert_equal(reopened.pages.read_page(0)[0].key.is_null, True)
        with assert_raises():
            _ = reopened.pages.read_page(-1)
        with assert_raises():
            _ = reopened.pages.read_page(44)


def test_paged_ranges_duplicates_null_masks_and_controls() raises:
    var rows = List[LanceBitmapRow]()
    for i in range(97):
        rows.append(LanceBitmapRow(LanceScalarKey.integer(Int64(i % 11)), UInt64(i)))
    rows.append(LanceBitmapRow(LanceScalarKey.null(2), UInt64.MAX))
    var index = _build(rows, 2, 7)
    assert_equal(index.pages.max_id, UInt64.MAX)
    var bitmap = LanceBitmapIndex.build(2, rows)
    for lower in range(-1, 13):
        for upper in range(-1, 13):
            for included in [False, True]:
                var query = LanceBitmapQuery.range_of(LanceBitmapBound(Optional(LanceScalarKey.integer(Int64(lower))), included),
                    LanceBitmapBound(Optional(LanceScalarKey.integer(Int64(upper))), included))
                var actual = index.search(query)
                var expected = bitmap.search(query)
                assert_equal(actual.true_rows().values(), expected.true_rows().values())
                assert_equal(actual.nulls.values(), expected.nulls.values())
    var token = CancellationToken()
    var narrow = index.search(LanceBitmapQuery.equals(LanceScalarKey.integer(1)),
        control=Optional(QueryControl(token, max_candidates=32)))
    assert_equal(narrow.true_rows().count(), 9)
    var control = Optional(QueryControl(token, max_candidates=1))
    with assert_raises(contains="resource"):
        _ = index.search(LanceBitmapQuery.equals(LanceScalarKey.integer(1)), control=control.copy())
    token.cancel()
    with assert_raises(contains="cancel"):
        _ = index.search(LanceBitmapQuery.is_in([]), control=control.copy())
    var empty = _build([], 2)
    assert_equal(empty.pages.row_count, 0)
    assert_equal(empty.search(LanceBitmapQuery.is_null()).selected_rows.count(), 0)
    with assert_raises(contains="duplicate"):
        _ = _build([LanceBitmapRow(LanceScalarKey.integer(1), 0), LanceBitmapRow(LanceScalarKey.integer(2), 0)], 2)


def test_paged_codec_rejects_torn_and_semantically_corrupt_payloads() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var index = _build([LanceBitmapRow(LanceScalarKey.integer(1), 0), LanceBitmapRow(LanceScalarKey.integer(2), 1)], 2, 1)
    ref source = index.pages.artifact[]
    var bytes = source._mapping.copy_scalars[DType.uint8](36, source.payload_length)
    # Recompute the envelope CRC so payload semantic validation is exercised.
    for cut in range(len(bytes)):
        var truncated = List[UInt8]()
        for i in range(cut):
            truncated.append(bytes[i])
        publish_cache(path, "bad.cache", CacheArtifact(CACHE_JSON_BTREE_KIND, 2, 0, 17, 42, truncated^))
        var artifact = load_cache_artifact(path + "/bad.cache")
        assert_true(Bool(artifact))
        with assert_raises():
            _ = map_btree_pages(ArcPointer(artifact.take()), "data", "$.v", 2, 2)
    # Header, null provenance, row count, page count, cardinality, null count,
    # offset, length, endpoint tag and endpoint value; every CRC remains valid.
    for offset in [0, 2, 3, 19, 23, 27, 31, 35, 39, 43, 44]:
        var bad = bytes.copy()
        bad[offset] = 255
        publish_cache(path, "bad.cache", CacheArtifact(CACHE_JSON_BTREE_KIND, 2, 0, 17, 42, bad^))
        var artifact = load_cache_artifact(path + "/bad.cache")
        with assert_raises():
            _ = map_btree_pages(ArcPointer(artifact.take()), "data", "$.v", 2, 2)
    var duplicate = bytes.copy()
    var second_id = index.pages.locations[1].offset - 36 + 9
    duplicate[second_id] = 0
    publish_cache(path, "bad.cache", CacheArtifact(CACHE_JSON_BTREE_KIND, 2, 0, 17, 42, duplicate^))
    var artifact = load_cache_artifact(path + "/bad.cache")
    with assert_raises(contains="duplicate"):
        _ = map_btree_pages(ArcPointer(artifact.take()), "data", "$.v", 2, 2)


def test_original_lance_paged_search_corpus() raises:
    var corpus = Python.import_module("json").loads(Python.import_module("builtins").open("tests/fixtures/lance-btree-leaf/cases.json").read())
    var searches = 0
    for scenario in corpus:
        var target = UInt8(Int(py=scenario["type"]))
        var rows = List[LanceBitmapRow]()
        for i in range(len(scenario["values"])):
            rows.append(LanceBitmapRow(_key(scenario["values"][i], target), UInt64(i)))
        var sizes = [1, 3, 7]
        for size in range(3):
            var index = _build(rows, target, sizes[size])
            for entry in scenario["queries"]:
                var query = _query(entry["query"], target)
                for track in range(2):
                    var actual = index.search(query, track_nulls=track == 1)
                    var expected = entry["paged"][size][track]
                    assert_equal(actual.selected_rows.values(), _ids(expected["selected"]), String(py=entry["query"]))
                    assert_equal(actual.nulls.values(), _ids(expected["nulls"]), String(py=entry["query"]))
                    searches += 1
    assert_equal(len(corpus), 16)
    assert_equal(searches, 24378)


def test_btree_publication_failure_replacement_and_large_leaf_boundary() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var first = _build([LanceBitmapRow(LanceScalarKey.integer(1), 0)], 2)
    publish_mapped_cache(path, "tree.cache", first.pages.artifact[])
    var loaded = load_cache_artifact(path + "/tree.cache")
    var held = LanceBTreeIndex(map_btree_pages(ArcPointer(loaded.take()), "data", "$.v", 2, 1))
    var second = _build([LanceBitmapRow(LanceScalarKey.integer(2), 0)], 2)
    var os = Python.import_module("os")
    os.mkdir(path + "/tree.cache.tmp")
    with assert_raises():
        publish_mapped_cache(path, "tree.cache", second.pages.artifact[])
    var unchanged = load_cache_artifact(path + "/tree.cache")
    var old = LanceBTreeIndex(map_btree_pages(ArcPointer(unchanged.take()), "data", "$.v", 2, 1))
    assert_equal(old.search(LanceBitmapQuery.equals(LanceScalarKey.integer(1))).selected_rows.count(), 1)
    os.rmdir(path + "/tree.cache.tmp")
    publish_mapped_cache(path, "tree.cache", second.pages.artifact[])
    var replacement = load_cache_artifact(path + "/tree.cache")
    var fresh = LanceBTreeIndex(map_btree_pages(ArcPointer(replacement.take()), "data", "$.v", 2, 1))
    assert_equal(fresh.search(LanceBitmapQuery.equals(LanceScalarKey.integer(2))).selected_rows.count(), 1)
    assert_equal(held.search(LanceBitmapQuery.equals(LanceScalarKey.integer(1))).selected_rows.count(), 1)
    var bytes = second.pages.artifact[]._mapping.copy_scalars[DType.uint8](0, second.pages.artifact[]._mapping.byte_length())
    bytes[len(bytes)-1] ^= 1
    with open(path + "/corrupt.cache", "w") as file:
        file.write_all(bytes)
    assert_equal(Bool(load_cache_artifact(path + "/corrupt.cache")), False)
    var key = LanceScalarKey.text(String(py=Python.import_module("builtins").str("x").__mul__(3 * 1024 * 1024)))
    var large = _build([LanceBitmapRow(key.copy(), 0), LanceBitmapRow(key.copy(), 1), LanceBitmapRow(key.copy(), 2)], 4, 4096)
    assert_equal(len(large.pages.locations), 2)
    assert_equal(large.pages.lookup.pages[0].row_count, 2)
    assert_equal(large.search(LanceBitmapQuery.equals(key.copy()), track_nulls=False).selected_rows.count(), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
