from akasha.document import JsonbValue
from std.memory import bitcast
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


def _unhex(value: PythonObject) raises -> List[UInt8]:
    var result = List[UInt8]()
    for byte in Python.import_module("builtins").bytes.fromhex(value):
        result.append(UInt8(Int(py=byte)))
    return result^


def _u64(value: PythonObject) raises -> UInt64:
    var text = String(py=value)
    var result = UInt64(0)
    for byte in text.bytes():
        result = result * 10 + UInt64(byte - 48)
    return result


def _int(value: PythonObject) raises -> Int64:
    return Int64(Int(py=Python.import_module("builtins").int(value)))


def _make(tree: PythonObject) raises -> JsonbValue:
    var kind = Int(py=tree[0])
    if kind == 5:
        return JsonbValue.null()
    if kind == 1:
        return JsonbValue.string(String(py=tree[1]))
    if kind == 2:
        return JsonbValue.integer(_int(tree[1]))
    if kind == 8:
        return JsonbValue.unsigned(_u64(tree[1]))
    if kind == 3:
        return JsonbValue.floating(bitcast[DType.float64](_u64(tree[1])))
    if kind == 4:
        return JsonbValue.boolean(Bool(py=tree[1]))
    if kind == 9:
        var bytes = _unhex(tree[1])
        return JsonbValue.decimal(Span(bytes), UInt8(Int(py=tree[2])))
    if kind == 10:
        var bytes = _unhex(tree[1])
        return JsonbValue.binary(Span(bytes))
    if kind == 11:
        return JsonbValue.date(Int32(_int(tree[1])))
    if kind == 12:
        return JsonbValue.timestamp(_int(tree[1]))
    if kind == 13:
        return JsonbValue.timestamp_tz(_int(tree[1]), Int32(_int(tree[2])))
    if kind == 14:
        return JsonbValue.interval(Int32(_int(tree[1])), Int32(_int(tree[2])), _int(tree[3]))
    var children = List[JsonbValue]()
    var keys = List[String]()
    for child in tree[1]:
        if kind == 7:
            keys.append(String(py=child[0]))
            children.append(_make(child[1]))
        else:
            children.append(_make(child))
    if kind == 7:
        return JsonbValue.object(keys, children)
    return JsonbValue.array(children)


def _compare(value: JsonbValue, tree: PythonObject) raises:
    var kind = Int(py=tree[0])
    assert_equal(value.kind(), kind)
    if kind == 1:
        assert_equal(value.as_string(), String(py=tree[1]))
    elif kind == 2:
        assert_equal(value.as_int(), _int(tree[1]))
    elif kind == 8:
        assert_equal(value.as_uint(), _u64(tree[1]))
    elif kind == 3:
        assert_equal(bitcast[DType.uint64](value.as_float()), _u64(tree[1]))
    elif kind == 4:
        assert_equal(value.as_bool(), Bool(py=tree[1]))
    elif kind == 9:
        assert_equal(value.decimal_bytes(), _unhex(tree[1]))
        assert_equal(value.decimal_scale(), UInt8(Int(py=tree[2])))
    elif kind == 10:
        assert_equal(value.as_binary(), _unhex(tree[1]))
    elif kind == 11:
        assert_equal(value.as_date(), Int32(_int(tree[1])))
    elif kind == 12 or kind == 13:
        assert_equal(value.as_timestamp(), _int(tree[1]))
        if kind == 13:
            assert_equal(value.timezone_offset(), Int32(_int(tree[2])))
    elif kind == 14:
        var interval = value.as_interval()
        assert_equal(interval[0], Int32(_int(tree[1])))
        assert_equal(interval[1], Int32(_int(tree[2])))
        assert_equal(interval[2], _int(tree[3]))
    elif kind == 6 or kind == 7:
        var children = value.children()
        assert_equal(len(children), len(tree[1]))
        if kind == 7:
            var keys = value.keys()
            for i in range(len(children)):
                assert_equal(keys[i], String(py=tree[1][i][0]))
                _compare(children[i], tree[1][i][1])
        else:
            for i in range(len(children)):
                _compare(children[i], tree[1][i])


def _fixture() raises -> PythonObject:
    return Python.import_module("json").loads(Python.import_module("pathlib").Path(
        "tests/fixtures/jsonb-codec/cases.json").read_text())


def test_original_jsonb_codec_and_builder_oracle() raises:
    var fixture = _fixture()
    var count = 0
    for row in fixture["cases"]:
        try:
            var expected = _unhex(row["hex"])
            var made = _make(row["input"])
            assert_equal(made.to_bytes(), expected)
            var decoded = JsonbValue(Span(expected))
            _compare(decoded, row["decoded"])
            assert_equal(decoded.clone().to_bytes(), expected)
        except err:
            print("JSONB codec mismatch", count, row["input"])
            raise err
        count += 1
    assert_equal(count, 6246)


def test_original_legacy_decimal_and_timezone_codec() raises:
    var fixture = _fixture()
    var count = 0
    for row in fixture["legacy"]:
        var bytes = _unhex(row["hex"])
        var value = JsonbValue(Span(bytes))
        _compare(value, row["decoded"])
        assert_equal(value.to_bytes(), bytes)
        var canonical = _make(row["decoded"])
        assert_equal(canonical.to_bytes(), _unhex(row["canonical_hex"]))
        count += 1
    assert_equal(count, 85)


def test_jsonb_null_is_valid_body_and_children_own_their_data() raises:
    var null = JsonbValue.null()
    assert_equal(null.kind(), 5)
    var null_bytes: List[UInt8] = [0x20, 0, 0, 0, 0, 0, 0, 0]
    assert_equal(null.to_bytes(), null_bytes)
    var storage_null = Optional[JsonbValue]()
    assert_true(not storage_null)
    var valid_null = Optional(null.clone())
    assert_true(Bool(valid_null))
    var strings: List[JsonbValue] = [JsonbValue.string("retained"), null.clone()]
    var array = JsonbValue.array(strings)
    var raw = array.to_bytes()
    var borrowed_source = JsonbValue(Span(raw))
    raw[0] = 0
    var children = borrowed_source.children()
    array = JsonbValue.null()
    borrowed_source = JsonbValue.null()
    assert_equal(children[0].as_string(), "retained")
    assert_equal(children[1].kind(), 5)


def test_jsonb_all_truncations_and_trailing_bytes() raises:
    var leaves: List[JsonbValue] = [JsonbValue.null(), JsonbValue.string("漢字\0😀"), JsonbValue.floating(-0.0),
                  JsonbValue.timestamp_tz(-1, 28800), JsonbValue.integer(Int64.MIN)]
    var array = JsonbValue.array(leaves)
    var object = JsonbValue.object(["nested", "empty"], [array.clone(), JsonbValue.object(List[String](), List[JsonbValue]())])
    leaves.append(array^)
    leaves.append(object^)
    for i in range(len(leaves)):
        var bytes = leaves[i].to_bytes()
        for end in range(len(bytes)):
            with assert_raises():
                _ = JsonbValue(Span(bytes)[:end])
        bytes.append(0)
        with assert_raises():
            _ = JsonbValue(Span(bytes))


def test_jsonb_rejects_corrupt_entries_utf8_and_duplicate_keys() raises:
    var malformed = ["00000000", "20000001ffffffff", "8000000100000001ff",
        "2000000090000000", "200000001000000180", "2000000020000000",
        "20000000200000021000", "20000000200000026000", "2000000060000000",
        "20000000600000021000", "2000000060000002f000", "200000005000000480000000",
        "800000015000000420000000", "80000001500000088000000000000000",
        "4000000200000000000000000000000000000000",
        "40000002100000011000000100000000000000006161"]
    for hex in malformed:
        var bytes = _unhex(PythonObject(hex))
        with assert_raises():
            _ = JsonbValue(Span(bytes))
    var values: List[JsonbValue] = [JsonbValue.null(), JsonbValue.boolean(True)]
    with assert_raises():
        _ = JsonbValue.object(["x", "x"], values)
    with assert_raises():
        _ = JsonbValue.object(["x"], values)
    with assert_raises():
        _ = JsonbValue.null().as_string()


def test_jsonb_resource_limits_before_publication() raises:
    var value = JsonbValue.null()
    for _ in range(64):
        value = JsonbValue.array([value.clone()])
    assert_equal(value._depth, 64)
    with assert_raises():
        _ = JsonbValue.array([value.clone()])
    var raw = value.to_bytes()
    var too_deep: List[UInt8] = [0x80, 0, 0, 1, 0x50, 0, 0, 0]
    for i in range(4):
        too_deep[4 + i] |= UInt8(UInt32(len(raw)) >> UInt32((3 - i) * 8))
    for byte in raw:
        too_deep.append(byte)
    with assert_raises():
        _ = JsonbValue(Span(too_deep))
    var large = List[UInt8](length=JsonbValue.MAX_BYTES + 1, fill=0)
    with assert_raises():
        _ = JsonbValue(Span(large))
    var array = List[UInt8](length=4 + 4 * (JsonbValue.MAX_NODES - 1), fill=0)
    array[0] = 0x80
    array[2] = 0xff
    array[3] = 0xff
    var maximum = JsonbValue(Span(array))
    assert_equal(maximum._node_count, JsonbValue.MAX_NODES)
    with assert_raises():
        _ = JsonbValue.array([maximum.clone()])
    array[1] = 1
    array[2] = 0
    array[3] = 0
    for _ in range(4):
        array.append(0)
    with assert_raises():
        _ = JsonbValue(Span(array))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
