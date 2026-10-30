from akasha.document import JsonbPath
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite


def _tree(path: JsonbPath, index: Int) raises -> PythonObject:
    ref node = path.nodes[index]
    var children = Python.list()
    for child in node.children:
        children.append(_tree(path, child))
    var result = Python.list()
    result.append(node.kind)
    result.append(node.a)
    result.append(node.b)
    result.append(PythonObject(node.text))
    result.append(PythonObject(String(node.bits)))
    result.append(children)
    return result


def test_complete_original_source_asts_and_rejections() raises:
    var json = Python.import_module("json")
    var cases = json.loads(Python.import_module("pathlib").Path("tests/fixtures/jsonb-path/cases.json").read_text())
    var builtins = Python.import_module("builtins")
    var accepted = 0
    var rejected = 0
    for row in cases:
        var bytes = List[UInt8]()
        for byte in builtins.bytes.fromhex(row["hex"]):
            bytes.append(UInt8(Int(py=byte)))
        try:
            if Bool(py=row.__contains__("ast")):
                var path = JsonbPath.parse_bytes(Span(bytes))
                var actual = Python.list()
                for root in path.roots:
                    actual.append(_tree(path, root))
                if not Bool(py=actual == row["ast"]):
                    print("actual", actual)
                    print("expected", row["ast"])
                    raise Error("source JSONB path AST mismatch")
                assert_equal(path.is_predicate(), Bool(py=row["predicate"]))
                accepted += 1
            else:
                with assert_raises():
                    _ = JsonbPath.parse_bytes(Span(bytes))
                rejected += 1
        except err:
            print("JSONB path source case", row["hex"])
            raise err
    assert_equal(accepted + rejected, len(cases))
    assert_equal(accepted, 4238)
    assert_equal(rejected, 4287)


def test_source_grammar_is_not_qdrant_or_generic_jsonpath() raises:
    var empty = JsonbPath.parse(" \t\n")
    assert_equal(len(empty.roots), 0)
    assert_false(empty.is_predicate())
    var numeric_field = JsonbPath.parse("1.0")
    assert_equal(numeric_field.nodes[numeric_field.roots[0]].text, "1")
    assert_equal(numeric_field.nodes[numeric_field.roots[1]].text, "0")
    assert_true(JsonbPath.parse("$.a == 1").is_predicate())
    assert_true(JsonbPath.parse("+$.a").is_predicate())
    assert_true(JsonbPath.parse("exists(@.x)").is_predicate())
    var raw = JsonbPath.parse("$.a&&b\tc")
    assert_equal(raw.nodes[raw.roots[1]].text, "a&&b\tc")
    for text in ["$.a == 1.0", "$.a + 1 + 2", "$[\"\"]", "$.\"", "$.\"unterminated", "@.x", "$[?(@.x == 1)]"]:
        with assert_raises():
            _ = JsonbPath.parse(text)
    var path = JsonbPath.parse("$[last--2147483648]")
    ref indexes = path.nodes[path.roots[1]]
    assert_equal(path.nodes[indexes.children[0]].b, Int(Int32.MAX))


def test_owned_fields_and_native_resource_bounds() raises:
    var text = String("$.漢字\\uD834\\uDD1E")
    var path = JsonbPath.parse(text)
    text = "changed"
    assert_equal(text, "changed")
    assert_equal(path.nodes[path.roots[1]].text, "漢字𝄞")
    var bytes = List[UInt8](length=JsonbPath.MAX_BYTES, fill=UInt8(97))
    assert_equal(JsonbPath.parse_bytes(Span(bytes)).nodes[0].text.byte_length(), JsonbPath.MAX_BYTES)
    bytes.append(97)
    with assert_raises():
        _ = JsonbPath.parse_bytes(Span(bytes))
    var deep = String("$.a == 1")
    for _ in range(JsonbPath.MAX_DEPTH + 1):
        deep = "(" + deep + ")"
    with assert_raises():
        _ = JsonbPath.parse(deep)
    var chain = String("$.a == 1")
    for _ in range(JsonbPath.MAX_DEPTH + 1):
        chain += " && $.a == 1"
    with assert_raises():
        _ = JsonbPath.parse(chain)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
