from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_reader import parse_jsonb
from akasha.document.jsonb_writer import format_jsonb
from akasha.query.control import QueryControl, CancellationToken
from std.python import Python
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def test_all_raw_jsonb_source_compact_and_pretty_outputs() raises:
    var json = Python.import_module("json")
    var pathlib = Python.import_module("pathlib")
    var builtins = Python.import_module("builtins")
    var cases = json.loads(pathlib.Path("tests/fixtures/jsonb-writer/cases.json").read_text())
    var accepted = 0
    var rejected = 0
    for row in cases:
        var bytes = List[UInt8]()
        for byte in builtins.bytes.fromhex(row["hex"]):
            bytes.append(UInt8(Int(py=byte)))
        var value = JsonbValue(Span(bytes))
        try:
            if Bool(py=row.__contains__("panic")):
                with assert_raises():
                    _ = format_jsonb(value)
                with assert_raises():
                    _ = format_jsonb(value, pretty=True)
                rejected += 1
            else:
                assert_equal(format_jsonb(value), String(py=row["compact"]))
                assert_equal(format_jsonb(value, pretty=True), String(py=row["pretty"]))
                accepted += 1
        except err:
            print("RawJsonb source output mismatch", row)
            raise err
    assert_equal(accepted, 28901)
    assert_equal(rejected, 102)


def test_semantic_loss_and_escaping_follow_source() raises:
    var value = parse_jsonb("{z:[NaN,Infinity,-Infinity,-0.0],a:'\\uD800'}")
    assert_equal(format_jsonb(value), "{\"a\":\"\\\\uD800\",\"z\":[null,null,null,-0.0]}")
    assert_equal(format_jsonb(parse_jsonb("[[],{},[1]]"), pretty=True), "[\n  [],\n  {},\n  [\n    1\n  ]\n]")
    var binary: List[UInt8] = [0, 10, 255]
    assert_equal(format_jsonb(JsonbValue.binary(Span(binary))), "\"000AFF\"")
    assert_equal(format_jsonb(JsonbValue.timestamp(-1)), "\"1969-12-31 23:59:59.999999\"")
    assert_equal(format_jsonb(JsonbValue.timestamp_tz(0, -1)), "\"1969-12-31 23:59:59.000000 -000001\"")
    assert_equal(format_jsonb(JsonbValue.date(-719529)), "\"-000001-12-31\"")
    with assert_raises():
        _ = format_jsonb(JsonbValue.date(Int32.MIN))
    with assert_raises():
        _ = format_jsonb(JsonbValue.timestamp_tz(0, 93600))


def test_checked_depth_nodes_and_expanding_output() raises:
    var text = String("null")
    for _ in range(JsonbValue.MAX_DEPTH):
        text = "[" + text + "]"
    var value = parse_jsonb(text)
    assert_equal(format_jsonb(value), text)
    var pretty = format_jsonb(value, pretty=True)
    assert_equal(format_jsonb(parse_jsonb(pretty)), text)
    var nodes = List[JsonbValue](capacity=JsonbValue.MAX_NODES - 1)
    for _ in range(JsonbValue.MAX_NODES - 1):
        nodes.append(JsonbValue.null())
    var array = JsonbValue.array(nodes)
    assert_equal(format_jsonb(array).byte_length(), 5 * (JsonbValue.MAX_NODES - 1) + 1)
    # Output is allowed to exceed the 16 MiB body limit by JSON escaping. The
    # valid input's existing byte/depth/node bounds still bound total work.
    var controls = List[UInt8](length=JsonbValue.MAX_BYTES - 8, fill=1)
    var large = JsonbValue.string(String(from_utf8=Span(controls)))
    var output = format_jsonb(large)
    assert_equal(output.byte_length(), 6 * len(controls) + 2)
    assert_equal(output.as_bytes()[0], UInt8(34))
    assert_equal(output.as_bytes()[1], UInt8(92))
    assert_equal(output.as_bytes()[output.byte_length() - 1], UInt8(34))


def test_output_limit_and_cooperative_query_control() raises:
    var value = parse_jsonb("null")
    assert_equal(format_jsonb(value, max_bytes=4), "null")
    for limit in [-1, 0, 3]:
        with assert_raises():
            _ = format_jsonb(value, max_bytes=limit)
    var escaped = JsonbValue.string("\x01")
    assert_equal(format_jsonb(escaped, max_bytes=8).byte_length(), 8)
    with assert_raises():
        _ = format_jsonb(escaped, max_bytes=7)
    var bytes = List[UInt8](length=1024, fill=UInt8(255))
    with assert_raises():
        _ = format_jsonb(JsonbValue.binary(Span(bytes)), max_bytes=32)
    var pretty = parse_jsonb("[{},[null]]")
    var text = format_jsonb(pretty, pretty=True)
    assert_equal(format_jsonb(pretty, pretty=True, max_bytes=text.byte_length()), text)
    with assert_raises():
        _ = format_jsonb(pretty, pretty=True, max_bytes=text.byte_length() - 1)
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=1)
    token.cancel()
    with assert_raises():
        _ = format_jsonb(value, control=control.copy())
    var active = CancellationToken()
    var expired = QueryControl(active, max_candidates=1, deadline_ns=1)
    with assert_raises():
        _ = format_jsonb(value, control=expired^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
