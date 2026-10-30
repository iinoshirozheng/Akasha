from bindings.arrow_payload import arrow_payload_schemas, arrow_payload_fields
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_raises, TestSuite


def _raw(text: String) raises -> PythonObject:
    var pa = Python.import_module("pyarrow")
    var values = Python.list()
    values.append(PythonObject(text))
    var raw = Python.import_module("akashadb.arrow_payload").payload_descriptor(
        pa.array(values, type=pa.string_view()), pa.field("text", pa.string_view()))
    raw["views"] = raw["views"].copy()
    return raw


def _read(raw: PythonObject) raises -> String:
    var columns = Python.list()
    columns.append(Python.dict(name="text", array=raw))
    var schemas = arrow_payload_schemas(columns, 1)
    var fields = arrow_payload_fields(schemas, columns, 0)
    return fields[0].value.as_string()


def test_native_view_length_padding_utf8_and_buffer_bounds() raises:
    var np = Python.import_module("numpy")
    var raw = _raw("short")
    raw["views"] = raw["views"][:15]
    with assert_raises():
        _ = _read(raw)
    raw = _raw("x")
    raw["views"][15] = 1
    with assert_raises():
        _ = _read(raw)
    raw = _raw("x")
    raw["views"][4] = 128
    with assert_raises():
        _ = _read(raw)
    for word in [0, 2, 3]:
        raw = _raw("a long string that uses a backing buffer")
        raw["views"].view(np.uint32)[word] = 4294967295
        with assert_raises():
            _ = _read(raw)
    raw = _raw("a long string that uses a backing buffer")
    raw["views"][4] = 0
    with assert_raises():
        _ = _read(raw)
    raw = _raw("a long string that uses a backing buffer")
    raw["data_buffers"] = Python.list()
    with assert_raises():
        _ = _read(raw)


def test_native_multiple_buffers_and_nonzero_external_offset() raises:
    var np = Python.import_module("numpy")
    var raw = _raw("a long string that uses a backing buffer")
    var original = raw["data_buffers"][0]
    var prefix = np.zeros(7, dtype=np.uint8)
    var arrays = Python.list()
    arrays.append(prefix)
    arrays.append(original)
    var buffers = Python.list()
    buffers.append(prefix)
    buffers.append(np.concatenate(arrays))
    raw["data_buffers"] = buffers
    raw["views"].view(np.uint32)[2] = 1
    raw["views"].view(np.uint32)[3] = 7
    assert_equal(_read(raw), "a long string that uses a backing buffer")


def test_native_null_masks_unreadable_view() raises:
    var np = Python.import_module("numpy")
    var raw = _raw("bad")
    raw["views"] = np.empty(0, dtype=np.uint8)
    raw["validity"] = np.zeros(1, dtype=np.uint8)
    var columns = Python.list()
    columns.append(Python.dict(name="text", array=raw))
    var schemas = arrow_payload_schemas(columns, 1)
    var fields = arrow_payload_fields(schemas, columns, 0)
    assert_equal(fields[0].value.kind(), UInt8(5))
    raw["nullable"] = False
    schemas = arrow_payload_schemas(columns, 1)
    with assert_raises():
        _ = arrow_payload_fields(schemas, columns, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
