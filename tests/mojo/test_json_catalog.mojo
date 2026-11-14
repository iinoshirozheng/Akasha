from akasha.index.json_catalog import JsonIndexCatalog, JsonIndexDefinition, encode_json_catalog, decode_json_catalog
from akasha.storage.filesystem import read_file_bytes
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


def test_btree_catalog_v2_and_v1_contract() raises:
    var catalog = JsonIndexCatalog()
    catalog.revision = 1
    catalog.definitions.append(JsonIndexDefinition("bitmap", "data", "v", 2))
    var old = encode_json_catalog(catalog)
    assert_equal(old[0], UInt8(1))
    assert_equal(decode_json_catalog(Span(old)).definitions[0].kind, UInt8(1))
    catalog.definitions.append(JsonIndexDefinition("tree", "data", "v", 2, 2))
    var bytes = encode_json_catalog(catalog)
    assert_equal(bytes[0], UInt8(2))
    var decoded = decode_json_catalog(Span(bytes))
    assert_equal(decoded.definitions[0].kind, UInt8(1))
    assert_equal(decoded.definitions[1].kind, UInt8(2))
    assert_equal(encode_json_catalog(decoded), bytes)
    var mislabeled = bytes.copy()
    mislabeled[0] = 1
    with assert_raises(contains="kind"):
        _ = decode_json_catalog(Span(mislabeled))
    catalog.definitions[1].kind = 3
    with assert_raises(contains="kind"):
        _ = encode_json_catalog(catalog)


def test_independent_mixed_kind_v2_fixture() raises:
    # Independently packed little-endian header/entries from the format spec.
    var bytes = read_file_bytes("tests/fixtures/json-catalog-v2.bin")
    var decoded = decode_json_catalog(Span(bytes))
    assert_equal(decoded.revision, UInt64(7))
    assert_equal(decoded.definitions[0].name, "bitmap")
    assert_equal(decoded.definitions[0].kind, UInt8(1))
    assert_equal(decoded.definitions[1].name, "tree")
    assert_equal(decoded.definitions[1].kind, UInt8(2))
    assert_equal(encode_json_catalog(decoded), bytes)
    bytes[24] = 3
    with assert_raises(contains="kind"):
        _ = decode_json_catalog(Span(bytes))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
