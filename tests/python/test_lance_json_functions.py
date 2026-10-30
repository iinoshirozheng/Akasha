from contextlib import closing
import json
from pathlib import Path
import re
import struct

import pyarrow as pa
import pytest

from akashadb import Collection, JsonbValue, PayloadField, ValidationError, CancellationToken
from akashadb import json_functions as jf

OPS = [getattr(jf, name) for name in jf.__all__]


@pytest.fixture(scope="module")
def source():
    return json.loads((Path(__file__).parents[1] / "fixtures/lance-json-functions/cases.json").read_text())


def normalize(values, op):
    if op == 4:
        return [None if v is None else v.hex() for v in values]
    if op == 7:
        return [None if v is None else struct.pack("!d", v).hex() for v in values]
    if op == 2:
        return [{"value": None if v["value"] is None else v["value"].hex(), "type_tag": v["type_tag"]} for v in values]
    return values


@pytest.mark.parametrize("op", range(11), ids=jf.__all__)
def test_all_original_lance_arrow_consumer_results(source, op):
    count = 0
    for index, row in enumerate(source):
        if str(op) not in row["results"]:
            continue
        count += 1
        expected = row["results"][str(op)]
        bodies = [None if b is None else bytes.fromhex(b) for b in row["bodies"]]
        if row.get("sliced"):
            bodies = pa.array([b"invalid-prefix"] + bodies, type=pa.large_binary()).slice(1)
            args = pa.array(["discard"] + row["args"], type=pa.string()).slice(1)
        else:
            bodies = pa.array(bodies, type=pa.large_binary())
            args = pa.array(row["args"], type=pa.string())
        call_args = [bodies, args]
        if op == 9:
            call_args.append(pa.array(row["values"], type=pa.string()))
        if "input_limit" in row:
            with pytest.raises(ValidationError, match="nesting depth exceeds limit"):
                OPS[op](*call_args)
        elif "error" in expected:
            with pytest.raises(ValidationError, match=re.escape(expected["error"])):
                OPS[op](*call_args)
        elif "panic" in expected:
            with pytest.raises(ValidationError):
                OPS[op](*call_args)
        else:
            result = OPS[op](*call_args)
            assert normalize(result.to_pylist(), op) == expected["ok"], (index, op)
            if op == 2:
                assert result.type == pa.struct([pa.field("value", pa.large_binary()), pa.field("type_tag", pa.uint8(), nullable=False)])
                assert result.null_count == 0
    assert count > 600


def test_scalar_methods_and_source_distinctions():
    doc = JsonbValue.from_json('{a:[1,2],n:null,x:2.5,truth:"YES",text:"hello"}')
    assert jf.json_path(doc, "$.a[*]") == "1"
    assert jf.json_extract(doc, "$.a[*]") == "[1,2]"
    assert jf.json_extract_with_type(doc, "$.a[*]")["type_tag"] == 5
    assert jf.json_extract_with_type(doc, "$.x")["type_tag"] == 3
    assert jf.json_extract_with_type(doc, "$.n")["value"].to_json() == "null"
    assert jf.json_extract_with_type(doc, "$.missing") == {"value": None, "type_tag": 0}
    assert jf.json_exists(doc, "$.x == 99") is True
    assert jf.json_get_int(doc, "x") == 3
    assert jf.json_get_float(doc, "x") == 2.5
    assert jf.json_get_bool(doc, "truth") is True
    assert jf.json_get_string(doc, "text") == "hello"
    assert jf.json_get(doc, "n").to_json() == "null"
    assert jf.json_get_int(doc, "n") is None
    assert jf.json_array_contains(doc, "$.a", "2") is True
    assert jf.json_array_length(doc, "$.x") == 0
    assert jf.json_array_length(doc, "$.missing") is None
    array = jf.json_get(doc, "a")
    assert jf.json_get_int(array, "+01") == 2
    for index in ["-0", "-1", "0.0", " 0", "18446744073709551616"]:
        assert jf.json_get(array, index) is None
    for function in OPS:
        args = [None, "$["] + (["x"] if function is jf.json_array_contains else [])
        assert function(*args) == ({"value": None, "type_tag": 0} if function is jf.json_extract_with_type else None)


def test_nullable_broadcast_row_order_and_failed_batch():
    data = pa.array([None, JsonbValue.from_json('{v:1.5}').data, JsonbValue.from_json('{v:null}').data], type=pa.large_binary())
    assert jf.json_get_int(data, "v").to_pylist() == [None, 2, None]
    assert jf.json_extract(data, pa.array(["$[", "$.v", "$"])).to_pylist() == [None, "1.5", '{"v":null}']
    assert jf.json_extract(pa.array([b"bad"], type=pa.large_binary()), None).to_pylist() == [None]
    assert jf.json_array_contains(data, "$[", None).to_pylist() == [None, None, None]
    with pytest.raises(ValidationError, match="InvalidJsonPath"):
        jf.json_extract(data, pa.array(["$", "$", "$["]))
    assert jf.json_get_int(data, "v").to_pylist() == [None, 2, None]
    assert jf.json_extract(pa.array([], type=pa.large_binary()), pa.array([], type=pa.string())).type == pa.string()
    with pytest.raises(ValidationError, match="resource limit"):
        jf.json_extract(pa.array([None, None], type=pa.large_binary()), None, max_bytes=8)
    with pytest.raises(ValidationError, match="resource limit"):
        jf.json_extract(data, pa.array([None]*65_537, type=pa.string()))


def test_types_lengths_limits_and_invalid_bodies():
    doc = JsonbValue.from_json('{a:[1,2,3]}')
    for value in [b"raw", "{}", pa.array(["{}"]), pa.array([doc.data], type=pa.binary())]:
        with pytest.raises(ValidationError):
            jf.json_extract(value, "$")
    for arg in [1, True, b"$", ["$"], pa.array(["$"], type=pa.large_string())]:
        with pytest.raises(ValidationError):
            jf.json_extract(doc, arg)
    data = pa.array([doc.data, doc.data], type=pa.large_binary())
    with pytest.raises(ValidationError, match="cover every row"):
        jf.json_extract(data, pa.array([], type=pa.string()))
    for options in [{"max_work": 0}, {"max_results": True}, {"max_bytes": 0}, {"timeout_ns": -1}, {"cancellation": True}]:
        with pytest.raises(ValidationError):
            jf.json_extract(doc, "$", **options)
    for options in [{"max_work": 1}, {"max_results": 1}, {"max_bytes": 1}]:
        with pytest.raises(ValidationError, match="resource limit"):
            jf.json_extract(doc, "$.a[*]", **options)
    token = CancellationToken();token.cancel()
    with pytest.raises(ValidationError, match="cancelled"):
        jf.json_extract(doc, "$", cancellation=token)
    with pytest.raises(ValidationError, match="deadline"):
        jf.json_extract(doc, "$", timeout_ns=1)
    for body in [b"", b"invalid", doc.data+b"\0"]:
        with pytest.raises(ValidationError):
            jf.json_extract(JsonbValue(body), "$")


def test_direct_native_transport_validation():
    from akashadb import _kernel
    options = dict(max_work=1_000_000,max_results=65_536,max_bytes=64*1024*1024,deadline_ns=0,cancelled=False)
    body = JsonbValue.from_json("[1]").data
    for bodies, args, needles, op in [([body],["$"],[],True),([body],["$"],[],11),([body],[1],[],1),(["bad"],["$"],[],1),([body],[],[],1),([body],["$"],[],9),(body,["$"],[],1)]:
        with pytest.raises(Exception):
            _kernel.lance_json(bodies,args,needles,op,options)
    assert _kernel.lance_json([body],["$"],[],1,options) == ["[1]"]
    with pytest.raises(Exception, match="output byte resource limit"):
        _kernel.lance_json([None, None], [None], [], 1, {**options, "max_bytes": 8})


@pytest.mark.parametrize("flush", [False, True])
def test_reopened_collection_values_and_owned_arrow_output(tmp_path, flush):
    field = PayloadField("json", "jsonb", JsonbValue.from_json('{a:[1,2],text:"owned"}'))
    with closing(Collection(tmp_path, 1)) as collection:
        collection.upsert(1, [1], [field])
        if flush: collection.flush()
    with closing(Collection(tmp_path, 1)) as collection:
        doc = collection.get(1).fields[0].value
        before = (tmp_path/"wal.bin").read_bytes();sequence=collection.last_sequence
        text = jf.json_get_string(doc, "text")
        owned = jf.json_get(doc, "a")
        batch = jf.json_extract_with_type(pa.array([doc.data],type=pa.large_binary()), "$.a[*]")
        with pytest.raises(ValidationError): jf.json_get_bool(doc, "a")
        assert collection.get(1).fields == [field]
        assert collection.last_sequence == sequence
        assert (tmp_path/"wal.bin").read_bytes() == before
    del doc
    assert text == "owned"
    assert jf.json_array_length(owned, "$") == 2
    assert JsonbValue(batch[0].as_py()["value"]).to_json() == "[1,2]"


def test_invalid_arrow_utf8_has_public_validation_error():
    data = pa.array([JsonbValue.from_json("{}").data], type=pa.large_binary())
    invalid = pa.Array.from_buffers(pa.string(), 1, [None, pa.py_buffer(struct.pack("=ii", 0, 1)), pa.py_buffer(b"\xff")])
    with pytest.raises(ValidationError, match="UTF8"):
        jf.json_extract(data, invalid)
