from contextlib import closing
import json
from pathlib import Path
import re
import struct

import pytest

from akashadb import Collection, JsonbValue, PayloadField, ValidationError


TARGETS = ("bool", "int64", "uint64", "float64", "string")


@pytest.fixture(scope="module")
def source():
    return json.loads((Path(__file__).parents[1] / "fixtures/jsonb-cast/cases.json").read_text())["casts"]


@pytest.mark.parametrize("target", TARGETS)
def test_all_source_casts_through_public_api(source, target):
    mode = TARGETS.index(target)
    for index, row in enumerate(source):
        value = JsonbValue(bytes.fromhex(row["hex"]))
        expected = row["casts"][mode]
        if "error" in expected:
            with pytest.raises(ValidationError, match=re.escape(expected["error"])):
                value.cast(target)
        elif "panic" in expected:
            with pytest.raises(ValidationError, match="source panic"):
                value.cast(target)
        else:
            result = value.cast(target)
            assert type(result) is (bool if mode == 0 else int if mode in (1, 2) else float if mode == 3 else str)
            if mode in (1, 2):
                result = str(result)
            elif mode == 3:
                result = str(struct.unpack("!Q", struct.pack("!d", result))[0])
            assert result == expected["ok"], (index, target, row)
    assert len(source) == 19975


@pytest.mark.parametrize("target", [None, True, 1, "int", "float", "", [], {}])
def test_target_requires_supported_exact_string(target):
    with pytest.raises(ValidationError):
        JsonbValue.from_json("1").cast(target)


def test_source_rounding_boolean_and_string_contracts():
    assert JsonbValue.from_json("1.5").cast("int64") == 2
    assert JsonbValue.from_json("-1.5").cast("int64") == -2
    assert JsonbValue.from_json('"-0.49"').cast("uint64") == 0
    assert JsonbValue.from_json('"9223372036854775807"').cast("int64") == 2**63-1
    assert JsonbValue.from_json('"18446744073709551615"').cast("uint64") == 2**64-1
    assert JsonbValue.from_json('"YeS"').cast("bool") is True
    assert JsonbValue.from_json('"No"').cast("bool") is False
    for text in ("0", "1", '"1"', '" true"', "null", "[]", "{}"):
        with pytest.raises(ValidationError):
            JsonbValue.from_json(text).cast("bool")
    value = JsonbValue.from_json('"a\\nb"')
    assert value.cast("string") == "a\nb"
    assert value.to_json() == '"a\\nb"'
    assert JsonbValue.from_json("true").cast("int64") == 1
    assert JsonbValue.from_json("false").cast("float64") == 0.0
    assert JsonbValue.from_json("NaN").cast("string") == "NaN"
    assert JsonbValue.from_json("Infinity").cast("string") == "inf"
    with pytest.raises(ValidationError):
        JsonbValue.from_json("Infinity").cast("int64")


def test_direct_binding_rejects_invalid_transport_and_corrupt_bodies():
    from akashadb import _kernel

    body = JsonbValue.from_json("1").data
    for raw, mode in [("1", 1), (bytearray(body), 1), (body, True), (body, "int64"), (body, -1), (body, 5), (body, 2**100), (b"", 1), (body+b"\0", 1)]:
        with pytest.raises(Exception):
            _kernel.cast_jsonb(raw, mode)
    for raw in [b"", b"invalid", body+b"\0"]:
        with pytest.raises(ValidationError):
            JsonbValue(raw).cast("int64")
    oversized = b"\0"*(16*1024*1024+1)
    with pytest.raises(ValueError, match="byte size"):
        JsonbValue(oversized)
    with pytest.raises(Exception, match="byte resource limit"):
        _kernel.cast_jsonb(oversized, 1)
    assert _kernel.cast_jsonb(body, 1) == 1


@pytest.mark.parametrize("flush", [False, True])
def test_reopened_values_cast_without_mutation(tmp_path, flush):
    fields = [PayloadField("json", "jsonb", JsonbValue.from_json('{price:1.5,flag:"YES",text:"hello"}'))]
    with closing(Collection(tmp_path, 1)) as collection:
        collection.upsert(1, [1], fields)
        if flush:
            collection.flush()
    with closing(Collection(tmp_path, 1)) as collection:
        value = collection.get(1).fields[0].value
        before = (tmp_path / "wal.bin").read_bytes()
        sequence = collection.last_sequence
        assert value.query("$.price", mode="first").cast("int64") == 2
        assert value.query("$.flag", mode="first").cast("bool") is True
        text = value.query("$.text", mode="first").cast("string")
        with pytest.raises(ValidationError):
            value.cast("int64")
        assert collection.get(1).fields == fields
        assert collection.last_sequence == sequence
        assert (tmp_path / "wal.bin").read_bytes() == before
    assert text == "hello"
