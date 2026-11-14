from akasha.storage.json_bitmap_shards import stage_json_bitmap, merge_json_bitmap_shards
from akasha.storage.json_bitmap_codec import encode_json_bitmap
from akasha.storage.index_cache import MappedCacheArtifact, decode_cache_bytes
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.index.lance_bitmap import LanceBitmapIndex, LanceBitmapRow
from akasha.index.lance_scalar import LanceScalarKey
from akasha.query.control import CancellationToken, QueryControl
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def test_shard_k_way_merge_matches_global_build_all_types() raises:
    var keys: List[LanceScalarKey] = [LanceScalarKey.boolean(True), LanceScalarKey.integer(-1),
        LanceScalarKey.float_bits(0x8000000000000000), LanceScalarKey.text("雪"), LanceScalarKey.binary([UInt8(0), 255])]
    for key in keys:
        var shards = List[ArcPointer[MappedCacheArtifact]]()
        var all_rows = List[LanceBitmapRow]()
        for shard in range(5):
            var rows = List[LanceBitmapRow]()
            for i in range(7):
                var value = LanceScalarKey.null(key.target) if i % 3 == 0 else key.copy()
                rows.append(LanceBitmapRow(value.copy(), UInt64(i)))
                all_rows.append(LanceBitmapRow(value^, UInt64(shard * 7 + i)))
            var index = LanceJsonBitmapIndex("$.v", LanceBitmapIndex.build(key.target, rows), shard != 3)
            shards.append(stage_json_bitmap("data", index, 2, UInt64(shard+1), 0, UInt32(shard)))
        var result = merge_json_bitmap_shards(shards, "data", "$.v", key.target, 2, 7, 42)
        var expected = LanceJsonBitmapIndex("$.v", LanceBitmapIndex.build(key.target, all_rows), False)
        assert_equal(encode_json_bitmap("data", result), encode_json_bitmap("data", expected))
        ref mapping = result._bitmap._mapped.value()[].artifact[]._mapping
        var envelope = decode_cache_bytes(mapping.copy_scalars[DType.uint8](0, mapping.byte_length()))
        assert_equal(envelope.payload, encode_json_bitmap("data", expected))
        assert_equal(len(result._bitmap._postings), 0)
        assert_equal(len(result._bitmap._shards), 5)
        assert_equal(result._bitmap._mapped.value()[].artifact[].sequence, UInt64(7))
        assert_equal(result._bitmap._mapped.value()[].artifact[]._mapping._descriptor_for_testing(), -1)


def test_shard_merge_interleaved_keys_empty_and_validation() raises:
    var shards = List[ArcPointer[MappedCacheArtifact]]()
    var all_rows = List[LanceBitmapRow]()
    for shard in range(4):
        var rows = List[LanceBitmapRow]()
        for i in range(17):
            var key = LanceScalarKey.integer(Int64((shard * 3 + i * 7) % 11))
            rows.append(LanceBitmapRow(key.copy(), UInt64(i)))
            all_rows.append(LanceBitmapRow(key^, UInt64(shard * 17 + i)))
        var index = LanceJsonBitmapIndex("$", LanceBitmapIndex.build(2, rows), True)
        shards.append(stage_json_bitmap("x", index, 3, UInt64(shard+1), 0, 0))
    var merged = merge_json_bitmap_shards(shards, "x", "$", 2, 3, 1, 0)
    var expected = LanceJsonBitmapIndex("$", LanceBitmapIndex.build(2, all_rows), True)
    assert_equal(encode_json_bitmap("x", merged), encode_json_bitmap("x", expected))
    with assert_raises():
        _ = merge_json_bitmap_shards(shards, "x", "$", 3, 3, 1, 0)
    with assert_raises():
        _ = merge_json_bitmap_shards(shards, "x", "$", 2, 4, 1, 0)
    with assert_raises():
        _ = merge_json_bitmap_shards(shards, "wrong", "$", 2, 3, 1, 0)
    with assert_raises():
        _ = merge_json_bitmap_shards([], "x", "$", 2, 3, 1, 0)
    var token = CancellationToken()
    token.cancel()
    with assert_raises(contains="cancel"):
        _ = merge_json_bitmap_shards(shards, "x", "$", 2, 3, 1, 0,
            Optional(QueryControl(token, max_candidates=100)))
    var empty = LanceJsonBitmapIndex("$", LanceBitmapIndex(2), True)
    var empty_shards = List[ArcPointer[MappedCacheArtifact]]()
    empty_shards.append(stage_json_bitmap("x", empty, 3, 1, 0, 0))
    var empty_merged = merge_json_bitmap_shards(empty_shards, "x", "$", 2, 3, 1, 0)
    assert_equal(encode_json_bitmap("x", empty_merged), encode_json_bitmap("x", empty))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
