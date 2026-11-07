from akasha.storage.json_bitmap_codec import encode_json_bitmap, decode_json_bitmap
from akasha.index.lance_bitmap import LanceBitmapIndex, LanceBitmapRow, LanceBitmapQuery
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from akasha.index.lance_scalar import LanceScalarKey
from std.testing import assert_equal, assert_raises, TestSuite


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
