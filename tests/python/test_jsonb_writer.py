from contextlib import closing
import json
from pathlib import Path

import pytest

from akashadb import Collection, JsonbValue, PayloadField, ValidationError


@pytest.mark.parametrize("pretty", [False, True])
def test_all_source_writer_cases_through_public_api(pretty):
    rows = json.loads((Path(__file__).parents[1]/"fixtures/jsonb-writer/cases.json").read_text())
    counts = [0, 0]
    for row in rows:
        raw = bytes.fromhex(row["hex"])
        value = JsonbValue(raw)
        if "panic" in row:
            with pytest.raises(ValidationError):
                value.to_json(pretty=pretty)
            counts[1] += 1
        else:
            assert value.to_json(pretty=pretty) == row["pretty" if pretty else "compact"], row
            counts[0] += 1
        assert value.data == raw
    assert counts == [28901, 102]


@pytest.mark.parametrize("pretty", [None, 0, 1, "false", []])
def test_pretty_requires_exact_bool(pretty):
    with pytest.raises(ValidationError):
        JsonbValue.from_json("null").to_json(pretty=pretty)


def test_binding_validates_body_size_and_types():
    from akashadb import _kernel
    from akashadb.payload import MAX_BYTES

    raw = JsonbValue.from_json("null").data
    for body, pretty in [("null", False), (bytearray(raw), False), (memoryview(raw), False), (raw, 1), (b"", False), (b"invalid", False), (raw+b"\0", False), (b"\0"*(MAX_BYTES+1), False)]:
        with pytest.raises(Exception):
            _kernel.format_jsonb(body, pretty)
    for body in (b"", b"invalid", raw+b"\0"):
        with pytest.raises(ValidationError):
            JsonbValue(body).to_json()


def test_text_projection_and_not_lossless_transport():
    value = JsonbValue.from_json("{z:[NaN,Infinity,-Infinity,-0.0],a:'\\uD800'}")
    text = value.to_json()
    assert text == '{"a":"\\\\uD800","z":[null,null,null,-0.0]}'
    assert JsonbValue.from_json(text) != value
    assert JsonbValue.from_json(text).to_json() == text
    assert JsonbValue.from_json(value.to_json(pretty=True)).to_json() == text
    # A source-valid binary extension displays uppercase hexadecimal as a JSON
    # string. Binary interchange continues to preserve the distinct type.
    binary = JsonbValue(bytes.fromhex("200000006000000400000aff"))
    assert binary.to_json() == '"000AFF"'
    assert JsonbValue.from_json(binary.to_json()) != binary


def test_nonfinite_bits_in_noncanonical_float_bodies():
    # RawJsonb's decoder also accepts these Float64 bodies even though its
    # builder emits dedicated NAN/INF tags. serde_json still writes null.
    for bits in (0x7ff0000000000000, 0xfff0000000000000, 0x7ff0000000000001, 0xffffffffffffffff):
        body = bytes.fromhex("200000002000000960") + bits.to_bytes(8, "big")
        value = JsonbValue(body)
        assert value.to_json() == "null"
        assert value.to_json(pretty=True) == "null"
        assert value.data == body


def test_output_growth_is_not_capped_at_binary_body_limit():
    size = 3 * 1024 * 1024
    body = bytes.fromhex("20000000") + (0x10000000 | size).to_bytes(4, "big") + b"\x01"*size
    value = JsonbValue(body)
    output = value.to_json()
    assert len(output) == 6*size+2
    assert output == '"' + "\\u0001"*size + '"'


@pytest.mark.parametrize("flush", [False, True])
def test_output_after_storage_reopen_and_errors_do_not_mutate(tmp_path, flush):
    value = JsonbValue.from_json("{z:[0x1.ab,NaN,,],a:'漢字😀'}")
    # The codec preserves all i32 day values. Formatting alone checks Jiff's
    # calendar range; it must not destroy or reinterpret the stored value.
    date = JsonbValue(bytes.fromhex("20000000600000051080000000"))
    fields = [PayloadField("json", "jsonb", value), PayloadField("date", "jsonb", date), PayloadField("nested", "array", [None, JsonbValue.from_json("null"), value])]
    compact, pretty = value.to_json(), value.to_json(pretty=True)
    with closing(Collection(tmp_path, 1)) as collection:
        collection.upsert(1, [1], fields)
        if flush:
            collection.flush()
    with closing(Collection(tmp_path, 1)) as collection:
        restored = collection.get(1).fields
        assert restored == fields
        assert restored[0].value.to_json() == compact
        assert restored[0].value.to_json(pretty=True) == pretty
        before = (tmp_path/"wal.bin").read_bytes()
        sequence = collection.last_sequence
        with pytest.raises(ValidationError):
            restored[1].value.to_json()
        assert (tmp_path/"wal.bin").read_bytes() == before
        assert collection.last_sequence == sequence
        assert collection.get(1).fields == fields
