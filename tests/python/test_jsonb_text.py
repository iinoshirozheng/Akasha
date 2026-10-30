from contextlib import closing
import json
from pathlib import Path

import pytest

from akashadb import Collection, JsonbValue, PayloadField, ValidationError, export_ndjson, import_ndjson


@pytest.mark.parametrize("mode,accepted,rejected", [("standard",11074,9683),("extended",16353,4404)])
def test_all_source_text_cases_through_python(mode, accepted, rejected):
    cases = json.loads((Path(__file__).parents[1]/"fixtures/jsonb-text/cases.json").read_text())
    counts = [0,0]
    for row in cases:
        raw, expected = bytes.fromhex(row["hex"]), row[mode]
        assert "panic" not in expected
        if "error" in expected:
            with pytest.raises(ValidationError):
                JsonbValue.from_json(raw, standard=mode == "standard")
            counts[1] += 1
        else:
            assert JsonbValue.from_json(raw, standard=mode == "standard").data.hex() == expected["hex"], row
            counts[0] += 1
    assert counts == [accepted,rejected]


@pytest.mark.parametrize("value", [None, 1, [], bytearray(b"null"), memoryview(b"null")])
def test_reject_input_conversion_protocols(value):
    with pytest.raises(ValidationError):
        JsonbValue.from_json(value)


@pytest.mark.parametrize("mode", [None, 0, 1, "false"])
def test_exact_bool_profile(mode):
    with pytest.raises(ValidationError):
        JsonbValue.from_json("null", standard=mode)


def test_unicode_input_and_source_profiles():
    assert JsonbValue.from_json('"漢字😀"') == JsonbValue.from_json('"漢字😀"'.encode())
    assert JsonbValue.from_json('"\\uD800"') == JsonbValue.from_json('"\\\\uD800"')
    assert JsonbValue.from_json("") == JsonbValue.from_json("null")
    assert JsonbValue.from_json("[1,,]") == JsonbValue.from_json("[1,null,null]", standard=True)
    with pytest.raises(ValidationError):
        JsonbValue.from_json(chr(0xD800))
    with pytest.raises(ValidationError):
        JsonbValue.from_json("+1", standard=True)


def test_native_limits_and_direct_binding_validation():
    from akashadb import _kernel
    from akashadb.payload import MAX_BYTES, MAX_NODES

    for raw,mode in [("null",False),(bytearray(b"null"),False),(b"null",1)]:
        with pytest.raises(Exception):
            _kernel.parse_jsonb(raw,mode)
    deep = '['*64+'null'+']'*64
    JsonbValue.from_json(deep)
    for raw in (f'[{deep}]', b' '*(MAX_BYTES+1), '['+','*(MAX_NODES-1)+']', '"'+'😀'*(MAX_BYTES//4)+'"'):
        with pytest.raises(ValidationError):
            JsonbValue.from_json(raw)


@pytest.mark.parametrize("flush", [False,True])
def test_parsed_values_storage_ndjson_and_invalid_write(tmp_path,flush):
    value = JsonbValue.from_json("{z:[1,,],a:'\\uD800',b:0x1.ab,n:NaN}")
    fields = [PayloadField("json","jsonb",value),PayloadField("array","array",[None,JsonbValue.from_json("null"),value])]
    with closing(Collection(tmp_path/'source',1)) as collection:
        collection.upsert(1,[1],fields)
        before = (tmp_path/'source/wal.bin').read_bytes()
        with pytest.raises(ValidationError):
            collection.upsert(2,[2],[PayloadField("invalid","jsonb",JsonbValue.from_json("{a:1,a:2}"))])
        assert collection.last_sequence == 1
        assert (tmp_path/'source/wal.bin').read_bytes() == before
        if flush:
            collection.flush()
    with closing(Collection(tmp_path/'source',1)) as collection:
        assert collection.get(1).fields == fields
        assert export_ndjson(collection,tmp_path/'values.ndjson') == 1
    with closing(Collection(tmp_path/'restored',1)) as restored:
        assert import_ndjson(restored,tmp_path/'values.ndjson') == 1
        assert restored.get(1).fields == fields
