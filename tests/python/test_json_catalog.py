"""Public JSON index operations exercise the compiled kernel and durable catalog."""
from contextlib import closing
import shutil

import pytest
from fastapi.testclient import TestClient

from akashadb import (CancellationToken, Collection, CollectionClosedError, JsonbValue,
                     LocalDatabase, PayloadField, PointMutation, ValidationError,
                     backup_collection, inspect_storage, restore_storage)
from apps.server.main import create_app


def predicate(operator="ge", value=2):
    return {"kind": "predicate", "projection": {
        "function": "json_get_int", "input": "data", "argument": "v"},
        "operator": operator, "value": value}


def populate(db):
    db.apply_point_batch([PointMutation.upsert(i, fields=[PayloadField(
        "data", "jsonb", JsonbValue.from_json('{"v":' + str(v) + '}'))])
        for i, v in [(-5, 1), (2, 2), (9, 3)]])


def test_python_catalog_query_and_reopen(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        assert db.query_json(predicate()) == [2, 9]
        db.create_json_index("v", "data", "$.v")
        assert db.json_indexes() == [{"name": "v", "column": "data", "path": "$.v", "target": 2, "kind": "bitmap"}]
        assert db.query_json(predicate(), indexes=["v"]) == [2, 9]
        before = (tmp_path / "manifest.bin").read_bytes()
        db.rebuild_json_index("v")
        assert (tmp_path / "manifest.bin").read_bytes() == before
        assert db.query_json(predicate(), indexes=["v"]) == [2, 9]
        db.flush()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.json_indexes()[0]["name"] == "v"
        assert db.query_json(predicate("eq", 1), indexes=["v"]) == [-5]
        db.drop_json_index("v")
        assert db.json_indexes() == []
    with closing(Collection(tmp_path, 1)) as db:
        assert db.json_indexes() == []


def test_http_catalog_reopen(tmp_path):
    database = LocalDatabase(tmp_path)
    with TestClient(create_app(database)) as client:
        assert client.post("/collections/demo", json={"dimension": 1}).status_code == 200
        populate(database.collection("demo"))
        response = client.put("/collections/demo/json-indexes/v", json={"column": "data", "path": "$.v"})
        assert response.status_code == 200, response.text
        query = {"expression": predicate(), "indexes": ["v"]}
        response = client.post("/collections/demo/json-query", json=query)
        assert response.status_code == 200, response.text
        assert response.json() == {"ids": [2, 9]}
        assert client.post("/collections/demo/json-indexes/v/rebuild").json() == {"rebuilt": True}
        assert client.post("/collections/demo/json-query", json={
            "expression": {"kind": "unknown"}}).status_code == 400
        assert client.post("/collections/demo/json-query", json={
            **query, "timeout_ns": True}).status_code == 422
        assert client.put("/collections/demo/json-indexes/v", json={
            "column": "data", "path": "$.v"}).status_code == 400
        assert client.delete("/collections/demo").status_code == 200
        assert client.post("/collections/demo", json={"dimension": 1}).status_code == 200
        assert client.get("/collections/demo/json-indexes").json()["indexes"][0]["name"] == "v"
        assert client.post("/collections/demo/json-query", json=query).json() == {"ids": [2, 9]}
        assert client.delete("/collections/demo/json-indexes/v").status_code == 200
        assert client.get("/collections/demo/json-indexes").json() == {"indexes": []}
        assert client.post("/collections/demo/json-query", json=query).status_code == 400
        assert client.post("/collections/demo/json-indexes/v/rebuild").status_code == 400


@pytest.mark.parametrize("expression", [
    {"kind": "unknown"},
    {"kind": "all", "children": [], "typo": True},
    {**predicate(), "value": "wrong type"},
])
def test_invalid_expression_rejected_by_native_parser(tmp_path, expression):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        with pytest.raises(ValidationError):
            db.query_json(expression)
        assert db.query_json(predicate()) == [2, 9]


def test_prepared_query_owns_snapshot_after_mutation_drop_and_close(tmp_path):
    db = Collection(tmp_path, 1)
    populate(db)
    db.create_json_index("v", "data", "$.v")
    with db.prepare_json(predicate(), indexes=["v"]) as prepared:
        db.apply_point_batch([PointMutation.delete(9)])
        db.drop_json_index("v")
        assert db.query_json(predicate()) == [2]
        db.close()
        assert prepared.execute() == [2, 9]
        assert prepared.execute() == [2, 9]
    prepared.close()
    with pytest.raises(CollectionClosedError):
        prepared.execute()


def test_json_query_controls_and_reuse_after_cancel(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        cancelled = CancellationToken()
        cancelled.cancel()
        with pytest.raises(ValidationError, match="cancel"):
            db.prepare_json(predicate(), cancellation=cancelled)
        with pytest.raises(ValidationError, match="cancel"):
            db.query_json(predicate(), cancellation=cancelled)
        with db.prepare_json(predicate()) as prepared:
            with pytest.raises(ValidationError, match="cancel"):
                prepared.execute(cancellation=cancelled)
            with pytest.raises(ValidationError):
                prepared.execute(timeout_ns=1)
            assert prepared.execute() == [2, 9]


def test_catalog_backup_captures_definition_and_restores_query(tmp_path):
    source, backup, restored = [tmp_path / name for name in ("source", "backup", "restored")]
    with closing(Collection(source, 1)) as db:
        populate(db)
        db.create_json_index("v", "data", "$.v")
        report = backup_collection(db, backup)
        assert report.valid and report.format_version == 6
        db.drop_json_index("v")
        db.apply_point_batch([PointMutation.delete(9)])
    assert inspect_storage(backup, 1).valid
    assert restore_storage(backup, restored, 1).valid
    with closing(Collection(restored, 1)) as db:
        assert db.json_indexes()[0]["name"] == "v"
        assert db.query_json(predicate(), indexes=["v"]) == [2, 9]


def test_catalog_publication_boundaries_recover_only_committed_manifest(tmp_path):
    source = tmp_path / "source"
    with closing(Collection(source, 1)) as db:
        populate(db)
        db.flush()
        old_manifest = (source / "manifest.bin").read_bytes()
        db.create_json_index("v", "data", "$.v")
        created_manifest = (source / "manifest.bin").read_bytes()
        db.drop_json_index("v")
        dropped_manifest = (source / "manifest.bin").read_bytes()
    # Catalog-only transitions retain authoritative point files. Reconstruct
    # disk states immediately before/after atomic manifest rename, as the
    # native checkpoint crash tests do. Temporary bytes are never authority.
    for transition, before, after, old_names, new_names in [
        ("create", old_manifest, created_manifest, [], ["v"]),
        ("drop", created_manifest, dropped_manifest, ["v"], []),
    ]:
        for boundary, temporary in enumerate((b"", after[:len(after)//2], after, None)):
            path = tmp_path / f"{transition}-{boundary}"
            shutil.copytree(source, path)
            (path / "manifest.bin").write_bytes(after if temporary is None else before)
            if temporary is not None:
                (path / "manifest.bin.tmp").write_bytes(temporary)
            with closing(Collection(path, 1)) as db:
                assert [item["name"] for item in db.json_indexes()] == (
                    new_names if temporary is None else old_names)
                assert db.query_json(predicate()) == [2, 9]
                db.apply_point_batch([PointMutation.delete(9)])
                db.flush()
            with closing(Collection(path, 1)) as db:
                assert db.query_json(predicate()) == [2]


def test_catalog_publish_io_failure_requires_reopen(tmp_path):
    db = Collection(tmp_path, 1)
    populate(db)
    db.flush()
    before = (tmp_path / "manifest.bin").read_bytes()
    temporary = tmp_path / "manifest.bin.tmp"
    temporary.mkdir()  # deterministic failure opening the publication file
    try:
        with pytest.raises(ValidationError):
            db.create_json_index("v", "data", "$.v")
        assert (tmp_path / "manifest.bin").read_bytes() == before
        with pytest.raises(ValidationError, match="reopen"):
            db.apply_point_batch([PointMutation.delete(9)])
    finally:
        temporary.rmdir()
        db.close()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.json_indexes() == []
        assert db.query_json(predicate()) == [2, 9]
        db.create_json_index("v", "data", "$.v")
        assert db.query_json(predicate(), indexes=["v"]) == [2, 9]


def test_corrupt_committed_catalog_is_not_replaced_by_valid_temporary(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        db.create_json_index("v", "data", "$.v")
    manifest = tmp_path / "manifest.bin"
    valid = manifest.read_bytes()
    (tmp_path / "manifest.bin.tmp").write_bytes(valid)
    manifest.write_bytes(valid[:-1])
    with pytest.raises(ValidationError):
        Collection(tmp_path, 1)
    assert manifest.read_bytes() == valid[:-1]
    manifest.write_bytes(valid)
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(predicate(), indexes=["v"]) == [2, 9]


def test_rebuild_preserves_learned_type_and_old_prepared_view(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        db.create_json_index("v", "data", "$.v")
        with db.prepare_json(predicate(), indexes=["v"]) as prepared:
            db.apply_point_batch([PointMutation.upsert(9, fields=[PayloadField(
                "data", "jsonb", JsonbValue.from_json('{"v":"different"}'))])])
            with pytest.raises(ValidationError):
                db.rebuild_json_index("v")
            assert db.json_indexes()[0]["target"] == 2
            assert prepared.execute() == [2, 9]
            db.apply_point_batch([PointMutation.upsert(9, fields=[PayloadField(
                "data", "jsonb", JsonbValue.from_json('{"v":0}'))])])
            db.rebuild_json_index("v")
            assert db.query_json(predicate(), indexes=["v"]) == [2]


@pytest.mark.parametrize("operator,value,expected", [
    ("eq", 2, [2]), ("ne", 2, [-5, 9]), ("lt", 2, [-5]),
    ("le", 2, [-5, 2]), ("gt", 2, [9]), ("ge", 2, [2, 9]),
])
def test_public_comparison_operators(tmp_path, operator, value, expected):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        db.create_json_index("v", "data", "$.v")
        assert db.query_json(predicate(operator, value)) == expected
        assert db.query_json(predicate(operator, value), indexes=["v"]) == expected


@pytest.mark.parametrize("changes", [
    {"operator": "in", "values": "bad"},
    {"operator": "in", "values": [True]},
    {"operator": "eq", "value": 2**63},
    {"operator": "eq", "value": []},
    {"operator": "eq", "value": {}},
    {"operator": "eq", "value": {"float_bits": "0"}},
    {"operator": "eq", "value": {"float_bits": "gg00000000000000"}},
    {"operator": "eq", "value": {"binary": "0"}},
    {"operator": "eq", "value": {"binary": "", "float_bits": "0000000000000000"}},
    {"operator": "between", "lower": 1, "include_lower": 1},
    {"operator": "between", "upper": 2, "include_upper": "yes"},
    {"operator": "is_null", "value": 0},
    {"operator": "unknown", "value": 1},
])
def test_public_literal_and_operator_validation(tmp_path, changes):
    spec = predicate()
    spec.pop("value")
    spec.update(changes)
    with closing(Collection(tmp_path, 1)) as db:
        with pytest.raises(ValidationError):
            db.prepare_json(spec)


def test_public_logical_range_null_and_size_boundaries(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        db.apply_point_batch([PointMutation.upsert(10)])
        leaf = predicate()
        leaf.pop("value")
        assert db.query_json({**leaf, "operator": "is_null"}) == [10]
        assert db.query_json({**leaf, "operator": "in", "values": [None, 2]}) == [2]
        assert db.query_json({"kind": "not", "child": {
            **leaf, "operator": "in", "values": []}}) == [-5, 2, 9, 10]
        assert db.query_json({**leaf, "operator": "between", "lower": 1,
                              "upper": 3, "include_lower": False, "include_upper": False}) == [2]
        assert db.query_json({"kind": "any", "children": [predicate("eq", 1), predicate("eq", 3)]}) == [-5, 9]
        nested = predicate("eq", 2)
        for _ in range(15):
            nested = {"kind": "all", "children": [nested]}
        assert db.query_json(nested) == [2]
        with pytest.raises(ValidationError):
            db.query_json({"kind": "all", "children": [nested]})
        assert db.query_json({"kind": "all", "children": [predicate("eq", 2)] * 255}) == [2]
        with pytest.raises(ValidationError):
            db.query_json({"kind": "all", "children": [predicate("eq", 2)] * 256})


def test_public_typed_float_and_binary_literals(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db)
        spec = predicate("eq", {"float_bits": "4000000000000000"})
        spec["projection"]["function"] = "json_get_float"
        assert db.query_json(spec) == [2]
        spec["projection"]["function"] = "json_get"
        spec["value"] = {"binary": JsonbValue.from_json("2").data.hex()}
        assert db.query_json(spec) == [2]
