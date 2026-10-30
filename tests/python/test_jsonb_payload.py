from contextlib import closing
import json
import math
from pathlib import Path
import struct

import pytest

from akashadb import (Collection, JsonbValue, PayloadField, PointMutation,
                      ValidationError, VectorField, export_ndjson, import_ndjson,
                      restore_storage)
from akashadb.payload import decode_value, encode_value


NULL = JsonbValue(bytes.fromhex("2000000000000000"))
TEXT = JsonbValue(bytes.fromhex("200000001000000178"))
TIME = JsonbValue(bytes.fromhex("200000006000000d30ffffffffffffffff00007080"))


def _fields():
    return [PayloadField("root", "jsonb", TIME), PayloadField("mixed", "array", [
        None, NULL, {"": TEXT, "nul\0key": -0.0, "type": "jsonb", "value": NULL.data.hex()},
        {"encoding": "typed", "type": "jsonb", "value": "ordinary JSON"},
    ]), PayloadField("plain", "null", None)]


def _assert_fields(actual):
    assert actual == _fields()
    assert actual[1].value[0] is None and actual[1].value[1] == NULL
    assert math.copysign(1, actual[1].value[2]["nul\0key"]) == -1


@pytest.mark.parametrize("category", ["cases", "legacy"])
def test_all_actual_source_bodies_through_public_api_and_ndjson(tmp_path, category):
    fixture = json.loads((Path(__file__).parents[1] / "fixtures/jsonb-codec/cases.json").read_text())
    cases = fixture[category]
    assert len(cases) == (6246 if category == "cases" else 85)
    values = [JsonbValue(bytes.fromhex(row["hex"])) for row in cases]
    with closing(Collection(tmp_path / "source", 2)) as source:
        for start in range(0, len(values), 256):
            source.apply_point_batch([
                PointMutation.upsert(i, fields=[PayloadField("value", "jsonb", values[i])])
                for i in range(start, min(len(values), start + 256))])
        for i, value in enumerate(values):
            assert source.get_point(i).fields == [PayloadField("value", "jsonb", value)], i
        assert export_ndjson(source, tmp_path / "all.ndjson") == len(values)
    with closing(Collection(tmp_path / "target", 2)) as target:
        assert import_ndjson(target, tmp_path / "all.ndjson") == len(values)
        target.flush()
    with closing(Collection(tmp_path / "target", 2)) as target:
        for i, value in enumerate(values):
            assert target.get_point(i).fields[0].value.data == value.data, i


@pytest.mark.parametrize("flush", [False, True])
@pytest.mark.parametrize("named", [False, True])
def test_nested_jsonb_ownership_wal_checkpoint_backup_and_reopen(tmp_path, flush, named):
    schema = {"embedding": VectorField(2)} if named else {}
    with closing(Collection(tmp_path / "source", 2, vectors=schema)) as source:
        fields = _fields()
        source.upsert(1, [1, 2], fields)
        fields[1].value.clear()
        detached = source.get(1)
        _assert_fields(detached.fields)
        detached.fields[1].value[2].clear()
        _assert_fields(source.get_point(1).fields)
        if flush:
            source.flush()
    with closing(Collection(tmp_path / "source", 2)) as reopened:
        _assert_fields(reopened.get(1).fields)
        reopened.backup(tmp_path / "backup")
    restore_storage(tmp_path / "backup", tmp_path / "restored", 2)
    with closing(Collection(tmp_path / "restored", 2)) as restored:
        _assert_fields(restored.get(1).fields)


def test_jsonb_payload_mutations_preserve_null_distinction_and_plain_objects(tmp_path):
    with closing(Collection(tmp_path, 2)) as source:
        source.upsert(1, [1, 2], _fields())
        source.set_payload({"plain": None, "json_null": NULL, "nested": [None, NULL]}, points=[1])
        values = {field.name: field.value for field in source.get(1).fields}
        assert "plain" not in values and values["json_null"] == NULL
        assert values["nested"] == [None, NULL]
        source.set_payload({"child": TEXT}, points=[1], key="object")
        assert {f.name: f.value for f in source.get(1).fields}["object"] == {"child": TEXT}
        source.overwrite_payload({"json_null": NULL, "plain": None}, points=[1])
        assert source.get(1).fields == [PayloadField("json_null", "jsonb", NULL), PayloadField("plain", "null", None)]
        source.delete_payload(["json_null"], points=[1])
        assert source.get(1).fields == [PayloadField("plain", "null", None)]


@pytest.mark.parametrize("hex_data", ["", "00", "00000000", "200000000000000000",
    "200000001000000180", "2000000020000000", "800000015000000420000000",
    "40000002100000011000000100000000000000006161"])
def test_invalid_jsonb_late_batch_member_leaves_wal_unchanged(tmp_path, hex_data):
    with closing(Collection(tmp_path, 2)) as source:
        source.upsert(9, [1, 2], _fields())
        before, sequence = (tmp_path / "wal.bin").read_bytes(), source.last_sequence
        with pytest.raises(ValidationError):
            source.apply_point_batch([
                PointMutation.upsert(1, fields=[PayloadField("ok", "jsonb", NULL)]),
                PointMutation.upsert(2, fields=[PayloadField("bad", "array", [JsonbValue(bytes.fromhex(hex_data))])]),
            ])
        assert source.get_point(1) is None and source.get_point(2) is None
        assert source.last_sequence == sequence
        assert (tmp_path / "wal.bin").read_bytes() == before


def test_python_jsonb_limits_include_internal_depth_nodes_and_bytes(tmp_path):
    deep = NULL.data
    for _ in range(64):
        # Complete original JSONB array with one container child, or scalar null.
        deep = bytes.fromhex("8000000100000000") if deep == NULL.data else struct.pack(
            ">II", 0x80000001, 0x50000000 | len(deep)) + deep
    maximum_nodes = struct.pack(">I", 0x8000ffff) + b"\0" * (4 * 65535)
    with closing(Collection(tmp_path, 2)) as source:
        source.upsert(1, [1, 2], [PayloadField("deep", "jsonb", JsonbValue(deep))])
        source.upsert(2, [1, 2], [PayloadField("many", "jsonb", JsonbValue(maximum_nodes))])
        before, sequence = (tmp_path / "wal.bin").read_bytes(), source.last_sequence
        bad = [PayloadField("deep", "array", [JsonbValue(deep)]),
               PayloadField("many", "array", [JsonbValue(maximum_nodes)])]
        for field in bad:
            with pytest.raises(ValidationError, match="depth|node"):
                source.upsert(3, [1, 2], [field])
        with pytest.raises(ValidationError, match="node"):
            source.upsert(3, [1, 2], [PayloadField("many", "jsonb", JsonbValue(maximum_nodes)), PayloadField("extra", "null", None)])
        with pytest.raises(ValueError, match="size"):
            JsonbValue(b"\0" * (16 * 1024 * 1024 + 1))
        assert source.last_sequence == sequence and (tmp_path / "wal.bin").read_bytes() == before


@pytest.mark.parametrize("data", [bytearray(NULL.data), memoryview(NULL.data), NULL.data.hex(), list(NULL.data)])
def test_jsonb_requires_immutable_bytes(data):
    with pytest.raises(TypeError, match="immutable bytes"):
        JsonbValue(data)


def test_typed_wire_is_explicit_and_preserves_ordinary_marker_keys():
    for field in _fields():
        wire = field.to_wire()
        assert PayloadField.from_wire(json.loads(json.dumps(wire))) == field
    ordinary = PayloadField("ordinary", "object", {"type": "jsonb", "value": NULL.data.hex(), "encoding": "typed"})
    assert ordinary.to_wire() == ordinary.to_kernel()
    assert PayloadField.from_wire(ordinary.to_wire()) == ordinary
    assert decode_value(encode_value([NULL, None, ordinary.value])) == [NULL, None, ordinary.value]
    integers = [-(2**63), 0, 1, 2**63, 2**64 - 1]
    wire = encode_value(integers)
    assert all(child["type"] == "integer" for child in wire["value"])
    assert decode_value(wire) == integers
    for kind in ["int", "uint"]:
        field = PayloadField("root", kind, 1)
        assert PayloadField.from_wire(field.to_wire(typed=True)) == field
        with pytest.raises(ValueError, match="integer wire tag"):
            decode_value({"type": "array", "value": [{"type": kind, "value": 1}]})
    floating = PayloadField("float", "float", 1).to_wire(typed=True)
    assert type(floating["value"]) is float
    assert PayloadField.from_wire(floating).value == 1.0


def test_jsonb_carrier_does_not_relax_filter_or_formula_configuration(tmp_path):
    from akashadb import Formula, QueryRequest, SearchRequest

    with closing(Collection(tmp_path, 2)) as source:
        source.upsert(1, [1, 2], _fields())
        with pytest.raises(ValidationError, match="JSON"):
            source.search(SearchRequest(metric="dot", k=1, vector=[1, 2], filter={
                "kind": "field", "key": "root", "match": {"value": NULL}}))
        with pytest.raises(ValidationError, match="JSON"):
            source.query(QueryRequest("formula", prefetch=(QueryRequest(),),
                                     formula=Formula("x", {"x": NULL})))


def test_jsonb_input_conversion_rechecks_owner_after_python_reentry(tmp_path, monkeypatch):
    source = Collection(tmp_path, 2)
    source.upsert(9, [1, 2])
    before = (tmp_path / "wal.bin").read_bytes()
    original = JsonbValue.__getattribute__

    def close_on_data(value, name):
        if name == "data":
            source.close()
        return original(value, name)

    monkeypatch.setattr(JsonbValue, "__getattribute__", close_on_data)
    with pytest.raises(Exception, match="closed"):
        source.upsert(1, [1, 2], [PayloadField("value", "jsonb", NULL)])
    assert (tmp_path / "wal.bin").read_bytes() == before


@pytest.mark.parametrize("encode", [False, True])
def test_typed_transport_rejects_cycles_and_combined_node_exhaustion(encode):
    cycle = []
    if encode:
        cycle.append(cycle)
        operation = lambda: encode_value(cycle)
    else:
        node = {"type": "array", "value": cycle}
        cycle.append(node)
        operation = lambda: decode_value(node)
    with pytest.raises(ValueError, match="depth"):
        operation()
    value = [None] * 65536
    if encode:
        operation = lambda: encode_value(value)
    else:
        node = {"type": "array", "value": [{"type": "null", "value": None}] * 65536}
        operation = lambda: decode_value(node)
    with pytest.raises(ValueError, match="node"):
        operation()


@pytest.mark.parametrize("version", [2, 3])
def test_independent_logical_format_fixtures(tmp_path, version):
    from akashadb.logical_points import decode_header

    path = Path(__file__).parents[1] / f"fixtures/logical-points/v{version}.ndjson"
    config, schema = decode_header(json.loads(path.read_text().splitlines()[0]))
    with closing(Collection(tmp_path, config.dimension, config=config, vectors=schema)) as target:
        assert import_ndjson(target, path) == 1
        if version == 2:
            assert target.get(4).fields == [PayloadField("value", "object", {"empty": [], "max": 2**64-1, "null": None})]
        else:
            value = target.get(4).fields[0].value
            assert value == [None, NULL, TIME, {"type": "jsonb", "value": "ordinary"}, 2**64-1, -0.0]
            assert math.copysign(1, value[-1]) == -1


@pytest.mark.parametrize("node", [
    {"type": "jsonb", "value": "00 00"}, {"type": "jsonb", "value": "0"},
    {"type": "jsonb", "value": "xx"}, {"type": "jsonb", "value": None},
    {"type": "jsonb", "value": "", "extra": True}, {"type": "new", "value": 1},
    {"type": "array", "value": [None]}, {"type": "object", "value": {"x": 1}},
    {"type": "int", "value": True}, {"type": "uint", "value": -1},
    {"type": "float", "value": float("inf")}, {"type": "null", "value": False},
])
def test_invalid_typed_wire_rejected(node):
    with pytest.raises(ValueError):
        decode_value(node)


@pytest.mark.parametrize("change", ["binary", "hex", "tag", "encoding", "legacy", "depth"])
def test_invalid_jsonb_logical_import_is_atomic(tmp_path, change):
    path = tmp_path / "values.ndjson"
    with closing(Collection(tmp_path / "source", 2)) as source:
        for i in [1, 2]:
            source.upsert(i, [1, 2], _fields())
        export_ndjson(source, path)
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    field = rows[-1]["fields"][0]
    if change == "binary":
        field["value"] = "00000000"
    elif change == "hex":
        field["value"] = "bad hex"
    elif change == "tag":
        field["type"] = "future"
    elif change == "encoding":
        field.pop("encoding")
    elif change == "legacy":
        rows[0]["version"] = 2
        for row in rows[1:]:
            for value in row["fields"]:
                value.pop("encoding")
    else:
        node = {"type": "null", "value": None}
        for _ in range(65):
            node = {"type": "array", "value": [node]}
        field.update(node)
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
    with closing(Collection(tmp_path / "target", 2)) as target:
        target.upsert(9, [1, 2])
        before, sequence = (target.path / "wal.bin").read_bytes(), target.last_sequence
        with pytest.raises((ValueError, ValidationError)):
            import_ndjson(target, path)
        assert target.get_point(1) is None
        assert target.last_sequence == sequence and (target.path / "wal.bin").read_bytes() == before


def test_http_jsonb_write_read_and_typed_updates(tmp_path):
    from fastapi.testclient import TestClient
    from akashadb import LocalDatabase
    from apps.server.main import create_app

    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        assert client.post("/collections/demo", json={"dimension": 2}).status_code == 200
        wire = [field.to_wire() for field in _fields()]
        assert client.post("/collections/demo/points", json={"id": 1, "vector": [1, 2], "fields": wire}).status_code == 200
        assert client.get("/collections/demo/points/1").json()["fields"] == wire
        assert client.post("/collections/demo/points/payload", json={
            "points": [1], "encoding": "typed", "payload": {"new": encode_value([None, NULL, TEXT])},
        }).status_code == 200
        returned = client.get("/collections/demo/points/1").json()["fields"]
        assert PayloadField.from_wire(returned[-1]).value == [None, NULL, TEXT]
        assert client.put("/collections/demo/points/payload", json={
            "points": [1], "encoding": "typed", "payload": {"only": encode_value(NULL)},
        }).status_code == 200
        expected = [PayloadField("only", "jsonb", NULL).to_wire()]
        assert client.get("/collections/demo/points/1").json()["fields"] == expected
        for field in [{"name": "bad", "type": "jsonb", "value": "00000000", "encoding": "typed"},
                      {"name": "bad", "type": "jsonb", "value": "xx", "encoding": "typed"},
                      {"name": "bad", "type": "jsonb", "value": NULL.data.hex()}]:
            assert client.post("/collections/demo/points", json={"id": 1, "vector": [1, 2], "fields": [field]}).status_code == 400
            assert client.get("/collections/demo/points/1").json()["fields"] == expected
        assert client.post("/collections/demo/points/payload", json={
            "points": [1], "encoding": "typed", "payload": {"bad": {"type": "jsonb", "value": "xx"}},
        }).status_code == 400
