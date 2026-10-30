from bindings.arrow_payload import ArrowPayloadSchema, arrow_payload_schemas, arrow_payload_fields
from akasha.document.record import DocumentField
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_raises, TestSuite


def _descriptor(source: String, dtype: PythonObject) raises -> PythonObject:
    var pa = Python.import_module("pyarrow")
    var adapter = Python.import_module("akashadb.arrow_payload")
    var values = Python.import_module("builtins").eval(PythonObject(source), Python.dict())
    return adapter.payload_descriptor(pa.array(values, type=dtype), pa.field("data", dtype))


def _fields(raw: PythonObject, row: Int) raises -> List[DocumentField]:
    var columns = Python.list()
    columns.append(Python.dict(name="data", array=raw))
    var schemas = arrow_payload_schemas(columns, Int(py=raw["row_count"]))
    return arrow_payload_fields(schemas, columns, row)


def test_uint64_and_explicit_null() raises:
    var pa = Python.import_module("pyarrow")
    var raw = _descriptor("[18446744073709551615, None]", pa.uint64())
    var maximum = _fields(raw, 0)
    assert_equal(maximum[0].value.as_uint(), UInt64.MAX)
    var null_value = _fields(raw, 1)
    assert_equal(null_value[0].value.kind(), UInt8(5))


def test_large_list_preserves_null_elements() raises:
    var pa = Python.import_module("pyarrow")
    var raw = _descriptor("[[1, None, -2], None]", pa.large_list(pa.int64()))
    var values = _fields(raw, 0)
    var children = values[0].value.children()
    assert_equal(len(children), 3)
    assert_equal(children[0].as_int(), Int64(1))
    assert_equal(children[1].kind(), UInt8(5))
    assert_equal(children[2].as_int(), Int64(-2))


def test_native_required_null_and_offset_rejection() raises:
    var pa = Python.import_module("pyarrow")
    var np = Python.import_module("numpy")
    var raw = _descriptor("[1, None]", pa.int64())
    raw["nullable"] = False
    with assert_raises():
        _ = _fields(raw, 1)
    raw = _descriptor("[[1], [2]]", pa.list_(pa.int64()))
    raw["offsets"] = np.array(Python.import_module("builtins").eval("[0, 1, 99]", Python.dict()), dtype="int32")
    with assert_raises():
        _ = _fields(raw, 1)


def test_native_schema_depth_and_duplicate_names() raises:
    var pa = Python.import_module("pyarrow")
    var raw = _descriptor("[1]", pa.int64())
    for _ in range(65):
        var children = Python.list()
        children.append(raw)
        raw = Python.dict(kind=8, bits=0, size=0, name="item", nullable=True, children=children)
    with assert_raises():
        _ = ArrowPayloadSchema(raw)
    var members = Python.list()
    members.append(pa.field("a", pa.int64()))
    members.append(pa.field("b", pa.int64()))
    raw = _descriptor("[{'a': 1, 'b': 2}]", pa.struct(members))
    raw["children"][1]["name"] = "a"
    with assert_raises():
        _ = ArrowPayloadSchema(raw)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
