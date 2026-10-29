from akasha.document.json_path import FormulaVariable, JsonPath, key_needs_quoting
from akasha.document.unicode_alphanumeric import is_alphanumeric
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_raises, TestSuite


def _fixture() raises -> PythonObject:
    return Python.import_module("json").loads(Python.import_module("builtins").open(
        "tests/fixtures/qdrant-json-path/paths.json").read())


def _none(value: PythonObject) raises -> Bool:
    return Bool(py=value.__eq__(Python.none()))


def _assert_path(path: JsonPath, expected: PythonObject) raises:
    assert_equal(path.first_key, String(py=expected["first"]))
    assert_equal(path.display(), String(py=expected["display"]))
    var parts = expected["rest"]
    assert_equal(len(path.rest), len(parts))
    for j in range(len(parts)):
        var kind = String(py=parts[j][0])
        ref item = path.rest[j]
        if kind == "key":
            assert_equal(item.kind, UInt8(1))
            assert_equal(item.key, String(py=parts[j][1]))
        elif kind == "index":
            assert_equal(item.kind, UInt8(2))
            assert_equal(String(item.index), String(py=Python.import_module("builtins").str(parts[j][1])))
        else:
            assert_equal(item.kind, UInt8(3))


def test_json_paths_and_variables_match_qdrant_parser() raises:
    var cases = _fixture()["cases"]
    for i in range(len(cases)):
        var row = cases[i]
        var value = String(py=row["input"])
        assert_equal(key_needs_quoting(value), Bool(py=row["needs_quoting"]), value)
        if _none(row["path"]):
            with assert_raises():
                _ = JsonPath.parse(value)
        else:
            var path = JsonPath.parse(value)
            _assert_path(path, row["path"])
            assert_equal(JsonPath.parse(path.display()).display(), path.display())
        if _none(row["variable"]):
            with assert_raises():
                _ = FormulaVariable.parse(value)
        else:
            var parsed = FormulaVariable.parse(value)
            var expected = row["variable"]
            if Bool(py=expected.__contains__("score")):
                assert_equal(String(parsed.score_index.value()), String(py=Python.import_module("builtins").str(expected["score"])))
                assert_equal(Bool(parsed.path), False)
            else:
                assert_equal(Bool(parsed.score_index), False)
                _assert_path(parsed.path.value(), expected["payload"])


def test_json_path_operations_match_qdrant_source() raises:
    var pairs = _fixture()["pairs"]
    for i in range(len(pairs)):
        var pair = pairs[i]
        var a = JsonPath.parse(String(py=pair["left"]))
        var b = JsonPath.parse(String(py=pair["right"]))
        var stripped = a.strip_prefix(b)
        assert_equal(Bool(stripped), not _none(pair["strip"]))
        if stripped:
            assert_equal(stripped.value().display(), String(py=pair["strip"]))
        assert_equal(a.extend(b).display(), String(py=pair["extend"]))
        assert_equal(a.array_key().display(), String(py=pair["array"]))
        assert_equal(a.strip_wildcard_suffix().display(), String(py=pair["strip_wildcard"]))
        assert_equal(a.has_wildcard_suffix(), Bool(py=pair["has_wildcard"]))
        assert_equal(a.check_include_pattern(b), Bool(py=pair["include"]))
        assert_equal(a.check_exclude_pattern(b), Bool(py=pair["exclude"]))
        assert_equal(a.compatible(b), Bool(py=pair["compatible"]))


def test_unicode_alphanumeric_exhaustive_against_pinned_rust() raises:
    var raw = _fixture()["unicode_ranges"]
    var ranges = List[Tuple[Int, Int]]()
    for i in range(len(raw)):
        ranges.append((Int(py=raw[i][0]), Int(py=raw[i][1])))
    var index = 0
    for cp in range(0x110001):
        while index < len(ranges) and cp > ranges[index][1]:
            index += 1
        var expected = index < len(ranges) and cp >= ranges[index][0]
        assert_equal(is_alphanumeric(cp), expected)
    assert_equal(is_alphanumeric(-1), False)


def test_json_path_native_resource_limits() raises:
    var path = String("a")
    for _ in range(JsonPath.MAX_PARTS - 1):
        path += "[]"
    _ = JsonPath.parse(path)
    with assert_raises():
        _ = JsonPath.parse(path + "[]")
    var long = String()
    for _ in range(JsonPath.MAX_BYTES):
        long += "a"
    _ = JsonPath.parse(long)
    with assert_raises():
        _ = JsonPath.parse(long).array_key()
    with assert_raises():
        _ = JsonPath.parse(long).extend(JsonPath.parse("x"))
    with assert_raises():
        _ = JsonPath.parse(long + "a")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
