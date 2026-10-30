from akasha.document import parse_jsonb, parse_jsonb_bytes, JsonbValue
from akasha import PersistentCollection, DocumentField, PayloadValue
from akasha.storage.filesystem import read_file_bytes
from std.memory import bitcast
from std.python import Python
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def test_actual_source_both_text_profiles() raises:
    var json = Python.import_module("json")
    var pathlib = Python.import_module("pathlib")
    var builtins = Python.import_module("builtins")
    var cases = json.loads(pathlib.Path("tests/fixtures/jsonb-text/cases.json").read_text())
    var accepted = List[Int](length=2, fill=0)
    var rejected = List[Int](length=2, fill=0)
    for row in cases:
        var bytes = List[UInt8]()
        for b in builtins.bytes.fromhex(row["hex"]):
            bytes.append(UInt8(Int(py=b)))
        for mode in range(2):
            var expected = row["standard" if mode == 0 else "extended"]
            try:
                assert_true(not Bool(py=expected.__contains__("panic")))
                if Bool(py=expected.__contains__("error")):
                    with assert_raises():
                        _ = parse_jsonb_bytes(Span(bytes), standard=mode == 0)
                    rejected[mode] += 1
                else:
                    var value = parse_jsonb_bytes(Span(bytes), standard=mode == 0)
                    var body = List[UInt8]()
                    for b in builtins.bytes.fromhex(expected["hex"]):
                        body.append(UInt8(Int(py=b)))
                    assert_equal(value.to_bytes(), body)
                    accepted[mode] += 1
            except err:
                print("jsonb text mismatch", mode, row)
                raise err
    assert_equal(accepted[0], 11074)
    assert_equal(rejected[0], 9683)
    assert_equal(accepted[1], 16353)
    assert_equal(rejected[1], 4404)


def test_source_unicode_and_shared_standard_whitespace() raises:
    assert_equal(parse_jsonb('"\\uD800"').as_string(), "\\uD800")
    assert_equal(parse_jsonb('"\\u{D834}\\u{DD1E}"').as_string(), "𝄞")
    assert_equal(parse_jsonb('"\\uD800\\u0061"').as_string(), "\\uD800\\u0061")
    assert_equal(parse_jsonb('"\\uDfff"').as_string(), "\\uDfff")
    assert_equal(parse_jsonb('"a\n\x00b"', standard=True).as_string(), "a\n\x00b")
    assert_equal(parse_jsonb('\\n\\x0C42\\t', standard=True).as_uint(), UInt64(42))
    for text in List[String](["'a\\'b'", '"\\u{1f600}"', '"\\x41"', '"\\uZZZZ"']):
        with assert_raises():
            _ = parse_jsonb(text)


def test_source_extended_numbers_nulls_and_duplicate_keys() raises:
    assert_equal(parse_jsonb("").kind(), 5)
    with assert_raises():
        _ = parse_jsonb("", standard=True)
    var array = parse_jsonb("[1,,3,]").children()
    assert_equal(len(array), 4)
    assert_equal(array[1].kind(), 5)
    assert_equal(array[3].kind(), 5)
    assert_equal(parse_jsonb("0x1a.b").as_float(), Float64(26.6875))
    assert_equal(parse_jsonb("-0x8000000000000000").as_int(), Int64.MIN)
    assert_equal(parse_jsonb("1.").kind(), 8)
    assert_equal(bitcast[DType.uint64](parse_jsonb("-0.0").as_float()), UInt64(1) << 63)
    for text in List[String](["-NaN", "{a:1,'a':2}", '{"a":1,"\\u0061":2}', "0x100000000000000000000000000000000"]):
        with assert_raises():
            _ = parse_jsonb(text)


def test_resource_limits_before_recursive_work() raises:
    var text = String("null")
    for _ in range(64):
        text = "[" + text + "]"
    assert_equal(parse_jsonb(text)._depth, 64)
    with assert_raises():
        _ = parse_jsonb("[" + text + "]")
    var nodes = String("[")
    for _ in range(JsonbValue.MAX_NODES - 2):
        nodes += ","
    nodes += "]"
    assert_equal(parse_jsonb(nodes)._node_count, JsonbValue.MAX_NODES)
    with assert_raises():
        _ = parse_jsonb("[," + nodes + "]")
    var source = List[UInt8](length=JsonbValue.MAX_BYTES + 1, fill=32)
    with assert_raises():
        _ = parse_jsonb_bytes(Span(source))
    # Encoded headers/entries also count; acceptable source length does not
    # bypass the independent binary value size limit.
    var body = List[UInt8](length=JsonbValue.MAX_BYTES - 7, fill=97)
    body[0] = 34
    body[len(body) - 1] = 34
    _ = parse_jsonb_bytes(Span(body))
    body.append(32)
    body.insert(len(body) - 2, 97)
    body.insert(len(body) - 2, 97)
    with assert_raises():
        _ = parse_jsonb_bytes(Span(body))


def test_parsed_jsonb_ownership_and_durable_atomic_write() raises:
    var temporary = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=temporary.name)
    var text = String("{z:[1,,],a:'\\uD800',b:0x1.ab,n:NaN}")
    var parsed = parse_jsonb(text)
    text = "overwritten"
    assert_equal(text, "overwritten")
    var expected = parsed.to_bytes()
    var collection = PersistentCollection.open(path, 1)
    collection.upsert_document(1, [1], [DocumentField("j", PayloadValue.jsonb(parsed^))])
    var wal = read_file_bytes(path + "/wal.bin")
    with assert_raises():
        collection.upsert_document(2, [2], [DocumentField("j", PayloadValue.jsonb(parse_jsonb("{a:1,a:2}")))])
    assert_equal(collection.last_sequence(), UInt64(1))
    assert_equal(read_file_bytes(path + "/wal.bin"), wal)
    collection.close()
    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.get(1).value().get_field("j").value().as_jsonb().to_bytes(), expected)
    var snapshot = reopened.snapshot()
    reopened.upsert_document(1, [2], [DocumentField("j", PayloadValue.jsonb(parse_jsonb("null")))])
    reopened.flush()
    reopened.close()
    assert_equal(snapshot.get(1).value().get_field("j").value().as_jsonb().to_bytes(), expected)
    snapshot.close()
    var restored = PersistentCollection.open(path, 1)
    assert_equal(restored.get(1).value().get_field("j").value().as_jsonb().kind(), 5)
    restored.close()
    temporary.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
