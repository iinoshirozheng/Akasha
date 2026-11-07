from akasha.index.json_catalog import JsonIndexCatalog, JsonIndexDefinition, encode_json_catalog, decode_json_catalog
from std.testing import assert_equal, assert_raises, TestSuite


def test_catalog_roundtrip_and_rejection() raises:
    var empty = JsonIndexCatalog()
    var empty_bytes = encode_json_catalog(empty)
    assert_equal(len(empty_bytes), 12)
    assert_equal(decode_json_catalog(Span(empty_bytes)).revision, UInt64(0))
    var catalog = JsonIndexCatalog()
    catalog.revision = 42
    catalog.definitions.append(JsonIndexDefinition("價格", "data", "$.price", 3))
    var bytes = encode_json_catalog(catalog)
    var decoded = decode_json_catalog(Span(bytes))
    assert_equal(decoded.revision, UInt64(42))
    assert_equal(decoded.definitions[0].name, "價格")
    assert_equal(encode_json_catalog(decoded), bytes)
    for length in range(len(bytes)):
        with assert_raises():
            _ = decode_json_catalog(Span(bytes)[:length])
    var trailing = bytes.copy()
    trailing.append(0)
    with assert_raises():
        _ = decode_json_catalog(Span(trailing))
    for offset in [0, 24, 25, 26]:
        var corrupt = bytes.copy()
        corrupt[offset] = 255
        with assert_raises():
            _ = decode_json_catalog(Span(corrupt))
    catalog.definitions.append(catalog.definitions[0].copy())
    with assert_raises():
        _ = encode_json_catalog(catalog)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
