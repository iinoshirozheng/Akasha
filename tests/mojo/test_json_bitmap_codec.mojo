from akasha.storage.json_bitmap_codec import encode_json_bitmap, decode_json_bitmap, map_json_bitmap
from akasha.index.lance_bitmap import LanceBitmapIndex, LanceBitmapRow, LanceBitmapQuery, LanceBitmapBound
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.index.lance_scalar import LanceScalarKey
from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from max.algorithm import parallelize
from std.python import Python
from akasha.storage.index_cache import CacheArtifact, CACHE_JSON_BITMAP_KIND, publish_cache, load_cache_artifact
from akasha.storage.filesystem import remove_file_if_exists
from akasha.query.control import QueryControl, CancellationToken


def _mapped(path: String, payload: List[UInt8], target: UInt8, rows: Int,
            cache_bytes: Int = 8 * 1024 * 1024, entries: Int = 128) raises -> LanceJsonBitmapIndex:
    publish_cache(path, "posting.cache", CacheArtifact(CACHE_JSON_BITMAP_KIND, 2, 0, 0, 0, payload.copy()))
    var artifact = load_cache_artifact(path + "/posting.cache")
    return map_json_bitmap(artifact.take(), "data", "$.v", target, rows,
        cache_bytes=cache_bytes, cache_entries=entries)



def test_json_bitmap_codec_all_types_and_truncation() raises:
    var keys: List[LanceScalarKey] = [LanceScalarKey.boolean(True), LanceScalarKey.integer(-7),
        LanceScalarKey.float_bits(UInt64(0x8000000000000000)), LanceScalarKey.text("雪"),
        LanceScalarKey.binary([UInt8(0), 255])]
    for key in keys:
        var rows: List[LanceBitmapRow] = [LanceBitmapRow(key.copy(), 0),
            LanceBitmapRow(LanceScalarKey.null(key.target), 1), LanceBitmapRow(key.copy(), 2)]
        var index = LanceJsonBitmapIndex("$.v", LanceBitmapIndex.build(key.target, rows), False)
        var bytes = encode_json_bitmap("data", index)
        var decoded = decode_json_bitmap(Span(bytes), "data", "$.v", key.target, 3)
        assert_equal(encode_json_bitmap("data", decoded), bytes)
        assert_equal(decoded._bitmap._postings[0].values(), [UInt64(0), 2])
        assert_equal(decoded._bitmap._nulls.values(), [UInt64(1)])
        assert_equal(decoded._string_getter_safe, False)
        for length in range(len(bytes)):
            with assert_raises():
                _ = decode_json_bitmap(Span(bytes)[:length], "data", "$.v", key.target, 3)
        with assert_raises():
            _ = decode_json_bitmap(Span(bytes), "other", "$.v", key.target, 3)
        with assert_raises():
            _ = decode_json_bitmap(Span(bytes), "data", "$.v", key.target, 4)
        bytes.append(0)
        with assert_raises():
            _ = decode_json_bitmap(Span(bytes), "data", "$.v", key.target, 3)


def test_json_bitmap_codec_rejects_invalid_ordinals_and_headers() raises:
    var rows: List[LanceBitmapRow] = [LanceBitmapRow(LanceScalarKey.boolean(True), 0),
        LanceBitmapRow(LanceScalarKey.null(1), 1), LanceBitmapRow(LanceScalarKey.boolean(True), 2)]
    var index = LanceJsonBitmapIndex("$.v", LanceBitmapIndex.build(1, rows), True)
    var bytes = encode_json_bitmap("data", index)
    assert_equal(len(bytes), 67)
    # Version, provenance, Boolean encoding, cross-posting duplicate,
    # non-increasing posting and out-of-domain ordinal respectively.
    for corruption in [0, 3, 39, 51, 59]:
        var bad = bytes.copy()
        bad[corruption] = UInt8(2 if corruption < 51 else 1 if corruption == 51 else 0)
        with assert_raises():
            _ = decode_json_bitmap(Span(bad), "data", "$.v", 1, 3)
    var outside = bytes.copy()
    outside[59] = 3
    with assert_raises():
        _ = decode_json_bitmap(Span(outside), "data", "$.v", 1, 3)
    var empty = LanceJsonBitmapIndex("$.v", LanceBitmapIndex(3), True)
    var empty_bytes = encode_json_bitmap("data", empty)
    var decoded = decode_json_bitmap(Span(empty_bytes), "data", "$.v", 3, 0)
    assert_equal(decoded._bitmap._rows, 0)



def test_mapped_postings_lazy_lru_lifetime_and_operations() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var input: List[LanceBitmapRow] = [LanceBitmapRow(LanceScalarKey.integer(1), 0),
        LanceBitmapRow(LanceScalarKey.integer(2), 1), LanceBitmapRow(LanceScalarKey.integer(3), 2),
        LanceBitmapRow(LanceScalarKey.null(2), 3)]
    var owned = LanceJsonBitmapIndex("$.v", LanceBitmapIndex.build(2, input), True)
    var bytes = encode_json_bitmap("data", owned)
    var mapped = _mapped(path, bytes, 2, 4, entries=2)
    var store = mapped._bitmap._mapped.value().copy()
    assert_equal(store[].loads, 0)
    assert_equal(len(mapped._bitmap._postings), 0)
    assert_equal(mapped._bitmap.lookup(LanceScalarKey.integer(99)).count(), 0)
    assert_equal(store[].loads, 0)
    var held = mapped._bitmap.lookup(LanceScalarKey.integer(1))
    _ = mapped._bitmap.lookup(LanceScalarKey.integer(2))
    _ = mapped._bitmap.lookup(LanceScalarKey.integer(1))
    assert_equal(store[].hits, 1)
    _ = mapped._bitmap.lookup(LanceScalarKey.integer(3))
    assert_equal(store[].evictions, 1)
    _ = mapped._bitmap.lookup(LanceScalarKey.integer(2))
    assert_equal(store[].loads, 4)
    assert_equal(held.values(), [UInt64(0)])
    var failures = List[Int](length=8, fill=0)
    def query(worker: Int) {imm mapped, mut failures}:
        try:
            for i in range(30):
                var key = (worker + i) % 3
                assert_equal(mapped._bitmap.lookup(LanceScalarKey.integer(Int64(key + 1))).values(), [UInt64(key)])
        except:
            failures[worker] += 1
    parallelize(query, 8, 8)
    for failure in failures:
        assert_equal(failure, 0)
    assert_equal(len(store[]._cache), 2)
    var loads_before = store[].loads
    var hits_before = store[].hits
    assert_true(store[].retained_bytes <= store[].max_bytes)
    var token = CancellationToken()
    token.cancel()
    with assert_raises(contains="cancel"):
        _ = mapped._bitmap.lookup(LanceScalarKey.integer(2), Optional(QueryControl(token, max_candidates=10)))
    assert_equal(store[].loads, loads_before)
    assert_equal(store[].hits, hits_before)
    var byte_limited = _mapped(path, bytes, 2, 4, cache_bytes=store[].retained_bytes // 2)
    _ = byte_limited._bitmap.lookup(LanceScalarKey.integer(1))
    _ = byte_limited._bitmap.lookup(LanceScalarKey.integer(2))
    assert_equal(len(byte_limited._bitmap._mapped.value()[]._cache), 1)
    assert_equal(byte_limited._bitmap._mapped.value()[].evictions, 1)
    # Replacement and unlink leave the original mapped inode usable.
    var replacement = _mapped(path, bytes, 2, 4, cache_bytes=0)
    remove_file_if_exists(path + "/posting.cache")
    assert_equal(encode_json_bitmap("data", mapped), bytes)
    assert_equal(encode_json_bitmap("data", replacement), bytes)
    assert_equal(replacement._bitmap._mapped.value()[].retained_bytes, 0)
    assert_equal(len(replacement._bitmap._mapped.value()[]._cache), 0)
    var remap = Dict[UInt64, Optional[UInt64]]()
    remap[0] = Optional(UInt64(9))
    remap[2] = None
    assert_equal(mapped._bitmap.remapped(remap).lookup(LanceScalarKey.integer(1)).values(), [UInt64(9)])
    var additions: List[LanceBitmapRow] = [LanceBitmapRow(LanceScalarKey.integer(2), 8)]
    assert_equal(mapped._bitmap.updated(additions).lookup(LanceScalarKey.integer(2)).values(), [UInt64(1), 8])
    var range_query = LanceBitmapQuery.range_of(LanceBitmapBound(Optional(LanceScalarKey.integer(1))),
        LanceBitmapBound(Optional(LanceScalarKey.integer(3)), False))
    assert_equal(mapped._bitmap.search(range_query).true_rows().values(), [UInt64(0), 1])
    directory.cleanup()


def test_mapped_postings_types_and_corruption() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var keys = [LanceScalarKey.boolean(True), LanceScalarKey.integer(-7),
        LanceScalarKey.float_bits(UInt64(0x8000000000000000)), LanceScalarKey.text("雪"),
        LanceScalarKey.binary([UInt8(0), 255])]
    for key in keys:
        var input: List[LanceBitmapRow] = [LanceBitmapRow(key.copy(), 0), LanceBitmapRow(LanceScalarKey.null(key.target), 1)]
        var owned = LanceJsonBitmapIndex("$.v", LanceBitmapIndex.build(key.target, input), False)
        var bytes = encode_json_bitmap("data", owned)
        var mapped = _mapped(path, bytes, key.target, 2)
        assert_equal(mapped._bitmap._mapped.value()[].loads, 0)
        for query in [LanceBitmapQuery.equals(key.copy()), LanceBitmapQuery.is_in([key.copy()]), LanceBitmapQuery.is_null()]:
            var expected = owned._bitmap.search(query)
            var actual = mapped._bitmap.search(query)
            assert_equal(actual.selected_rows.values(), expected.selected_rows.values())
            assert_equal(actual.nulls.values(), expected.nulls.values())
        assert_equal(encode_json_bitmap("data", mapped), bytes)
        for length in range(len(bytes)):
            var truncated = List[UInt8]()
            truncated.extend(Span(bytes)[:length])
            with assert_raises():
                _ = _mapped(path, truncated, key.target, 2)
        # Valid envelope CRC around invalid duplicate posting ordinal.
        bytes[len(bytes)-8] = 1
        with assert_raises(contains="duplicate"):
            _ = _mapped(path, bytes, key.target, 2)
    directory.cleanup()

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
