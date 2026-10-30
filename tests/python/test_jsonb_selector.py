from contextlib import closing
import json
from pathlib import Path
import re

import pytest

from akashadb import CancellationToken, Collection, JsonbValue, PayloadField, ValidationError


MODES = ("values", "array", "first", "value", "exists", "predicate")


@pytest.fixture(scope="module")
def source():
    data = json.loads((Path(__file__).parents[1] / "fixtures/jsonb-selector/cases.json").read_text())
    return data, [JsonbValue(bytes.fromhex(raw)) for raw in data["docs"]], [bytes.fromhex(raw) for raw in data["paths"]]


@pytest.mark.parametrize("mode", MODES)
def test_all_original_modes_through_public_query(source, mode):
    data, docs, paths = source
    mode_id = MODES.index(mode)
    for index, row in enumerate(data["cases"]):
        value, path = docs[row["pair"][0]], paths[row["pair"][1]]
        if "modes" not in row:
            with pytest.raises(ValidationError):
                value.query(path, mode=mode)
            continue
        expected = row["modes"][mode_id]
        if "output_limit" in expected:
            with pytest.raises(ValidationError, match="resource limit"):
                value.query(path, mode=mode)
        elif "error" in expected:
            with pytest.raises(ValidationError, match=re.escape(expected["error"])):
                value.query(path, mode=mode)
        elif "panic" in expected:
            with pytest.raises(ValidationError):
                value.query(path, mode=mode)
        else:
            result = value.query(path, mode=mode)
            if mode == "values":
                result = [item.data.hex() for item in result]
            elif mode in ("array", "first", "value") and result is not None:
                result = result.data.hex()
            assert result == expected["ok"], (index, mode, path)
    assert len(data["cases"]) == 64856


@pytest.mark.parametrize("mode", [None, True, 1, "", "all", [], {}])
def test_mode_requires_a_supported_exact_string(mode):
    with pytest.raises(ValidationError):
        JsonbValue.from_json("null").query("$", mode=mode)


@pytest.mark.parametrize("path", [None, True, 1, [], bytearray(b"$"), memoryview(b"$"), "\ud800", b"\xff", "$"*65537, "漢"*65536])
def test_path_type_utf8_and_byte_bounds(path):
    with pytest.raises(ValidationError):
        JsonbValue.from_json("null").query(path)


@pytest.mark.parametrize("name", ["max_work", "max_results", "max_bytes", "timeout_ns"])
@pytest.mark.parametrize("value", [True, 0, -1, 1.0, "1", 2**63])
def test_exact_positive_integer_limits(name, value):
    with pytest.raises(ValidationError):
        JsonbValue.from_json("null").query("$", **{name: value})


def test_null_missing_cardinality_and_unknown_are_distinct():
    value = JsonbValue.from_json('{a:null,items:[1,2,3]}')
    assert value.query("$.missing", mode="first") is None
    assert value.query("$.a", mode="first").to_json() == "null"
    assert value.query("$.missing", mode="values") == []
    assert value.query("$.missing", mode="array").to_json() == "[]"
    assert value.query("$.items[*]", mode="value").to_json() == "[1,2,3]"
    assert value.query("$.items[*]", mode="first").to_json() == "1"
    assert value.query("$.a == 1", mode="predicate") is None
    assert value.query("$.missing == 1", mode="predicate") is False
    assert value.query("$.missing == 1", mode="exists") is True
    assert value.query("$.items[*]", mode="predicate") is None
    assert value.query("$.items[0,0 to 1,0]", mode="array").to_json() == "[1,1,2,1]"


def test_resources_precancellation_and_native_deadline():
    value = JsonbValue.from_json("[1,2,3]")
    for options in [dict(max_work=1), dict(max_results=2), dict(max_bytes=1)]:
        with pytest.raises(ValidationError, match="resource limit"):
            value.query("$[*]", **options)
    for mode in ("first", "exists"):
        with pytest.raises(ValidationError, match="resource limit"):
            value.query("$[*]", mode=mode, max_results=2)
    token = CancellationToken()
    token.cancel()
    with pytest.raises(ValidationError, match="cancelled"):
        value.query("$", cancellation=token)
    with pytest.raises(ValidationError, match="deadline"):
        value.query("$", timeout_ns=1)
    with pytest.raises(ValidationError, match="deadline"):
        value.query("$", timeout_ns=2**63-1)
    with pytest.raises(ValidationError, match="CancellationToken"):
        value.query("$", cancellation=True)
    for path in ("$[0 to -1]", "$[last to last--2147483648]"):
        with pytest.raises(ValidationError, match="resource limit"):
            value.query(path)
    with pytest.raises(ValidationError, match="resource limit"):
        JsonbValue.from_json("[]").query("$[0 to last]")
    # An existing maximum-depth value may be selected unchanged, but wrapping
    # it in another array would violate the established codec contract.
    deep = JsonbValue.from_json("["*64+"0"+"]"*64)
    assert deep.query("$", mode="first") == deep
    with pytest.raises(ValidationError, match="resource limit"):
        deep.query("$", mode="array")


def test_direct_binding_validates_every_transport_boundary():
    from akashadb import _kernel

    data = JsonbValue.from_json("null").data
    options = dict(max_work=100, max_results=100, max_bytes=1000, deadline_ns=0, cancelled=False)
    for raw, path, mode in [("null", b"$", 0), (bytearray(data), b"$", 0), (data, "$", 0), (data, bytearray(b"$"), 0), (data, b"$", True), (data, b"$", 6), (data, b"$", -1), (b"", b"$", 0), (data+b"\0", b"$", 0)]:
        with pytest.raises(Exception):
            _kernel.query_jsonb(raw, path, mode, options)
    for key in options:
        wrong = dict(options)
        wrong[key] = 0 if key == "cancelled" else True
        with pytest.raises(Exception):
            _kernel.query_jsonb(data, b"$", 0, wrong)
    for body in (b"", b"invalid", data+b"\0"):
        with pytest.raises(ValidationError):
            JsonbValue(body).query("$")
    assert _kernel.query_jsonb(data, b"$", 2, options) == data


@pytest.mark.parametrize("flush", [False, True])
def test_queries_after_reopen_remain_owned_and_do_not_write(tmp_path, flush):
    value = JsonbValue.from_json('{items:[{price:3},{price:9},{price:7}],a:NaN}')
    fields = [PayloadField("json", "jsonb", value), PayloadField("nested", "array", [None, value])]
    with closing(Collection(tmp_path, 1)) as collection:
        collection.upsert(1, [1], fields)
        if flush:
            collection.flush()
    with closing(Collection(tmp_path, 1)) as collection:
        restored = collection.get(1).fields
        before = (tmp_path / "wal.bin").read_bytes()
        sequence = collection.last_sequence
        selected = restored[0].value.query('$.items[*]?(@.price < 8)', mode="array")
        assert selected.to_json() == '[{"price":3},{"price":7}]'
        assert restored[1].value[1].query('$.items[1].price', mode="first").to_json() == "9"
        for path in ("$.items / 0", "$[", "$.items[0].price / 0"):
            with pytest.raises(ValidationError):
                restored[0].value.query(path)
        assert (tmp_path / "wal.bin").read_bytes() == before
        assert collection.last_sequence == sequence
        assert collection.get(1).fields == fields
    assert selected.to_json() == '[{"price":3},{"price":7}]'
    assert selected.query('$[*].price', mode="value").to_json() == "[3,7]"
