from contextlib import closing
import json
import math
from pathlib import Path
import struct
import zlib

import pytest

from akashadb import (Collection, PayloadField, PointMutation, ValidationError,
                      VectorField, SearchRequest, export_ndjson, import_ndjson, restore_storage)


def _fields():
    return [
        PayloadField("document", "object", {
            "z": [None, {"": "empty", "nul\0key": "中文😀", "a.b": -0.0}],
            "first": True, "last": {}, "uint": 2**64 - 1, "int": -(2**63),
        }),
        PayloadField("items", "array", [False, 0, 0.5, "x", [], {}]),
        PayloadField("nothing", "null", None),
        PayloadField("large", "uint", 2**64 - 1),
        PayloadField("small_uint", "uint", 1),
        PayloadField("rank", "int", 3),
    ]


def _assert_fields(actual, expected=None):
    expected = _fields() if expected is None else expected
    assert actual == expected
    value = actual[0].value
    assert list(value) == ["z", "first", "last", "uint", "int"]
    assert list(value["z"][1]) == ["", "nul\0key", "a.b"]
    assert math.copysign(1, value["z"][1]["a.b"]) == -1


@pytest.mark.parametrize("named", [False, True])
@pytest.mark.parametrize("flush", [False, True])
def test_owned_rich_payload_wal_segment_and_reopen(tmp_path, named, flush):
    schema = {"embedding": VectorField(2)} if named else {}
    db = Collection(tmp_path, 2, vectors=schema)
    fields = _fields()
    db.upsert(1, [1, 2], fields)
    _assert_fields(db.get(1).fields)
    _assert_fields(db.get_point(1).fields)
    fields[0].value["z"].append("caller mutation")
    detached = db.get(1)
    detached.fields[0].value["z"].clear()
    _assert_fields(db.get(1).fields)
    if flush:
        db.flush()
    db.close()
    with closing(Collection(tmp_path, 2)) as reopened:
        _assert_fields(reopened.get(1).fields)
        reopened.apply_point_batch([PointMutation.update(1, fields=[PayloadField("document", "int", 7)])])
        assert reopened.get(1).fields == [PayloadField("document", "int", 7)]
        reopened.apply_point_batch([PointMutation.update(1, fields=_fields())])
        _assert_fields(reopened.get_point(1).fields)


def test_rich_backup_restore_and_logical_v2(tmp_path):
    with closing(Collection(tmp_path / "source", 2, vectors={})) as source:
        source.upsert(1, [1, 2], _fields())
        source.backup(tmp_path / "backup")
        export_ndjson(source, tmp_path / "export.ndjson")
    restore_storage(tmp_path / "backup", tmp_path / "restored", 2)
    with closing(Collection(tmp_path / "restored", 2)) as restored:
        _assert_fields(restored.get(1).fields)
    rows = [json.loads(line) for line in (tmp_path / "export.ndjson").read_text().splitlines()]
    assert rows[0]["version"] == 2
    with closing(Collection(tmp_path / "imported", 2, vectors={})) as target:
        assert import_ndjson(target, tmp_path / "export.ndjson") == 1
        _assert_fields(target.get_point(1).fields)
        before = target.last_sequence
        rows[0]["version"] = 1
        (tmp_path / "bad.ndjson").write_text("".join(json.dumps(row) + "\n" for row in rows))
        with pytest.raises(ValueError, match="v1"):
            import_ndjson(target, tmp_path / "bad.ndjson")
        assert target.last_sequence == before


@pytest.mark.parametrize("bad", [float("nan"), float("inf"), 2**64, -(2**63)-1, {1: "key"}, (1, 2)])
def test_bad_nested_value_rejects_whole_batch_before_wal(tmp_path, bad):
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        db.upsert(9, [1, 2])
        before = (tmp_path / "wal.bin").read_bytes()
        sequence = db.last_sequence
        with pytest.raises(ValidationError):
            db.apply_point_batch([
                PointMutation.upsert(1, fields=[PayloadField("good", "null", None)]),
                PointMutation.upsert(2, fields=[PayloadField("bad", "array", [bad])]),
            ])
        assert db.last_sequence == sequence
        assert db.get_point(1) is None
        assert (tmp_path / "wal.bin").read_bytes() == before


@pytest.mark.parametrize("kind", ["cycle", "depth", "nodes", "bytes"])
def test_payload_limits_before_write(tmp_path, kind):
    value = []
    if kind == "cycle":
        value.append(value)
    elif kind == "depth":
        for _ in range(65):
            value = [value]
    elif kind == "nodes":
        value = [None] * 65_536
    else:
        value = ["x" * (16 * 1024 * 1024)]
    with closing(Collection(tmp_path, 2)) as db:
        before = db.last_sequence
        with pytest.raises(ValidationError):
            db.upsert(1, [1, 2], [PayloadField("bad", "array", value)])
        assert db.last_sequence == before
        assert db.get(1) is None


@pytest.mark.parametrize("corrupt", ["torn", "checksum", "version"])
def test_rich_payload_wal_torn_tail_and_corruption(tmp_path, corrupt):
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        db.upsert(9, [1, 2])
        db.flush()
        db.apply_point_batch([PointMutation.upsert(i, fields=_fields()) for i in (1, 2)])
    wal = bytearray((tmp_path / "wal.bin").read_bytes())
    if corrupt == "checksum":
        wal[-10] ^= 1
    elif corrupt == "version":
        # WAL v5: 40-byte batch header, 20-byte mutation header, u32 payload
        # length. Keep the outer CRC valid while corrupting the inner version.
        assert wal[64:68] == b"\xff" * 4
        wal[68] = 99
        wal[-4:] = struct.pack("<I", zlib.crc32(wal[4:-4]))
    else:
        del wal[-1]
    (tmp_path / "wal.bin").write_bytes(wal)
    if corrupt != "torn":
        with pytest.raises(Exception, match="checksum|CRC|crc|payload version"):
            Collection(tmp_path, 2)
    else:
        with closing(Collection(tmp_path, 2)) as reopened:
            assert reopened.get(9) is not None
            assert reopened.get_point(1) is None
            assert reopened.get_point(2) is None
            reopened.upsert(3, [1, 2], _fields())
            _assert_fields(reopened.get(3).fields)


@pytest.mark.parametrize("mode", ["eq_int", "ne_int", "eq_string", "ne_string", "eq_bool"])
def test_public_rich_filter_results_match_qdrant_before_and_after_reopen(tmp_path, mode):
    source = Path(__file__).parents[1] / "fixtures/qdrant-payload-values/values.json"
    cases = [case for case in json.loads(source.read_text())["filters"] if case["kind"] == mode]
    kinds = {str: "string", int: "int", float: "float", bool: "bool",
             list: "array", dict: "object", type(None): "null"}
    with closing(Collection(tmp_path, 2)) as db:
        for i, case in enumerate(cases):
            value = case["value"]
            kind = "uint" if type(value) is int and value > 2**63 - 1 else kinds[type(value)]
            db.upsert(i, [1, 0], [PayloadField("x", kind, value)])
        operator, kind = mode.split("_")
        literal = {"int": 2, "string": "2", "bool": True}[kind]
        request = SearchRequest("dot", len(cases), vector=[1, 0], filter={
            "kind": "condition", "name": "x", "operator": operator,
            "type": kind, "value": literal,
        })
        expected = {i for i, case in enumerate(cases) if case["matches"]}
        assert {hit.id for hit in db.search(request)} == expected
        db.flush()
    with closing(Collection(tmp_path, 2)) as db:
        assert {hit.id for hit in db.search(request)} == expected


def test_http_rich_payload_storage_and_validation(tmp_path):
    from dataclasses import asdict
    from fastapi.testclient import TestClient
    from akashadb import LocalDatabase
    from apps.server.main import create_app

    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        assert client.post("/collections/demo", json={"dimension": 2}).status_code == 200
        fields = [asdict(field) for field in _fields()]
        response = client.post("/collections/demo/points", json={
            "id": 1, "vector": [1, 0], "fields": fields,
        })
        assert response.status_code == 200, response.text
        assert client.get("/collections/demo/points/1").json()["fields"] == fields
        bad = client.post("/collections/demo/points", json={
            "id": 2, "vector": [1, 0],
            "fields": [{"name": "x", "type": "array", "value": {}}],
        })
        assert bad.status_code in (400, 422)
        assert client.get("/collections/demo/points/2").status_code == 404


def test_explicit_scalar_conversion_remains_distinct_from_json_contents(tmp_path):
    class Number:
        def __float__(self):
            return 2.5

    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(1, [1, 0], [PayloadField("weight", "float", Number()),
                              PayloadField("count", "float", 3)])
        assert db.get(1).fields == [PayloadField("weight", "float", 2.5),
                                    PayloadField("count", "float", 3.0)]
        with pytest.raises(ValidationError, match="JSON value"):
            db.upsert(2, [1, 0], [PayloadField("nested", "array", [Number()])])
        assert db.get(2) is None


def test_scalar_arrow_projection_rejects_rich_values_without_losing_data(tmp_path):
    from akashadb.arrow import scan_record_batches

    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(1, [1, 0], _fields())
        scanner = scan_record_batches(db, payload_schema={"document": "string"})
        with pytest.raises(Exception, match="payload type mismatch"):
            next(scanner)
        assert scanner.closed
        _assert_fields(db.get(1).fields)
