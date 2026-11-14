"""End-to-end native B-tree catalog, query, cache and snapshot contracts."""
from contextlib import closing
import json
import shutil
import struct
import zlib

import pytest
from fastapi.testclient import TestClient
from akashadb import (CancellationToken, Collection, JsonbValue, LocalDatabase,
                     PayloadField, PointMutation, ValidationError,
                     backup_collection, restore_storage, scan_record_batches)
from apps.server.main import create_app


def leaf(operator="ge", value=2, function="json_get_int"):
    result = {"kind": "predicate", "projection": {
        "function": function, "input": "data", "argument": "v"}, "operator": operator}
    if operator not in {"is_null", "in", "between"}:
        result["value"] = value
    return result


def populate(db, values):
    db.apply_point_batch([PointMutation.upsert(i, fields=[PayloadField(
        "data", "jsonb", JsonbValue.from_json(json.dumps({"v": value})))])
        for i, value in values])


def cache_file(path):
    files = list(path.glob("json-btree-*.cache"))
    assert len(files) == 1
    return files[0]


def test_large_paged_operators_null_guards_and_reopen(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db, [(i - 2500, None if i % 17 == 0 else i % 11) for i in range(5000)])
        db.create_json_index("tree", "data", "v", kind="btree")
        assert db.json_indexes() == [{"name": "tree", "column": "data", "path": "v", "target": 2, "kind": "btree"}]
        raw = cache_file(tmp_path).read_bytes()
        assert raw[6] == 6  # AKIC B-tree kind
        pos = 40  # 36-byte envelope + four-byte payload prefix
        for _ in range(2):
            length, = struct.unpack_from("<I", raw, pos)
            pos += 4 + length
        rows, pages = struct.unpack_from("<II", raw, pos)
        assert rows == 5000 and pages == 2
        expressions = [leaf(op, 3) for op in ("eq", "ne", "lt", "le", "gt", "ge")]
        expressions += [leaf("is_null"), {**leaf("in"), "values": [1, 3, 3]},
            {**leaf("in"), "values": []}, {**leaf("in"), "values": [None, 3]},
            {**leaf("between"), "lower": 2, "upper": 6, "include_lower": False},
            leaf("between"), leaf("eq", None)]
        for expression in expressions:
            for logical in (expression, {"kind": "not", "child": expression}):
                assert db.query_json(logical, indexes=["tree"]) == db.query_json(logical)
        db.flush()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.json_indexes()[0]["kind"] == "btree"
        assert db.query_json(leaf(), indexes=["tree"]) == db.query_json(leaf())
        db.rebuild_json_index("tree")


@pytest.mark.parametrize("value,function,target", [
    (True, "json_get_bool", 1), (-7, "json_get_int", 2),
    (1.25, "json_get_float", 3), ("雪", "json_get_string", 4),
])
def test_scalar_types_and_snapshot_after_drop_close(tmp_path, value, function, target):
    db = Collection(tmp_path, 1)
    populate(db, [(-5, value), (2, None), (9, value)])
    db.create_json_index("tree", "data", "v", kind="btree")
    expression = leaf("eq", value, function)
    assert db.json_indexes()[0]["target"] == target
    with db.prepare_json(expression, indexes=["tree"]) as prepared:
        assert prepared.execute() == [-5, 9]
        db.apply_point_batch([PointMutation.delete(9)])
        db.rebuild_json_index("tree")
        assert db.query_json(expression, indexes=["tree"]) == [-5]
        db.drop_json_index("tree")
        assert not list(tmp_path.glob("json-btree-*.cache"))
        db.close()
        assert prepared.execute() == [-5, 9]


def test_cache_corruption_torn_data_stale_source_and_failed_publication(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db, [(1, 1), (2, 2), (3, None)])
        db.create_json_index("tree", "data", "v", kind="btree")
    cache = cache_file(tmp_path)
    original = cache.read_bytes()
    for bad in (original[:20], original[:-1], original[:-4] + b"bad!"):
        cache.write_bytes(bad)
        with closing(Collection(tmp_path, 1)) as db:
            assert db.query_json(leaf(), indexes=["tree"]) == [2]
            assert cache.read_bytes() == bad  # snapshot demand never publishes
            db.rebuild_json_index("tree")
        assert cache.read_bytes() == original
    # A valid CRC cannot hide a structurally invalid leaf ordinal.
    corrupt = bytearray(original)
    struct.pack_into("<Q", corrupt, len(corrupt) - 12, 100)
    struct.pack_into("<I", corrupt, len(corrupt) - 4, zlib.crc32(corrupt[:-4]))
    cache.write_bytes(corrupt)
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(leaf(), indexes=["tree"]) == [2]
        db.rebuild_json_index("tree")
        temporary = cache.with_name(cache.name + ".tmp")
        temporary.mkdir()
        populate(db, [(2, 0), (-10, 3)])
        db.rebuild_json_index("tree")  # optional cache publication may fail
        assert cache.read_bytes() == original
        assert db.query_json(leaf(), indexes=["tree"]) == [-10]
        temporary.rmdir()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query_json(leaf(), indexes=["tree"]) == [-10]
        db.rebuild_json_index("tree")
        assert cache.read_bytes() != original


def test_shared_definitions_and_bitmap_kind_isolation(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db, [(1, 1), (2, 2), (3, None)])
        db.create_json_index("bitmap", "data", "v")
        db.create_json_index("tree", "data", "v", kind="btree")
        db.create_json_index("alias", "data", "v", kind="btree")
        path = cache_file(tmp_path)
        for indexes in (["tree", "bitmap"], ["bitmap", "tree"], ["alias"]):
            assert db.query_json(leaf(), indexes=indexes) == [2]
        db.drop_json_index("tree")
        assert path.exists()
        db.drop_json_index("bitmap")
        assert path.exists() and not list(tmp_path.glob("json-bitmap-*.cache"))
        db.drop_json_index("alias")
        assert not path.exists()


def test_arrow_owns_btree_snapshot_and_controls(tmp_path):
    db = Collection(tmp_path, 1)
    populate(db, [(i, i) for i in range(10)])
    db.create_json_index("tree", "data", "v", kind="btree")
    options = dict(columns=("id",), batch_size=2, json_expression=leaf(), indexes=["tree"],
                   json_columns={"v": leaf()["projection"]})
    token = CancellationToken()
    token.cancel()
    with pytest.raises(ValidationError, match="cancel"):
        scan_record_batches(db, **options, cancellation=token)
    with pytest.raises(ValidationError, match="candidate"):
        scan_record_batches(db, **options, max_candidates=2)
    scanner = scan_record_batches(db, **options)
    first = next(scanner)
    db.apply_point_batch([PointMutation.delete(9)])
    db.flush()
    db.drop_json_index("tree")
    db.close()
    with scanner:
        rows = first.to_pylist() + [row for batch in scanner for row in batch.to_pylist()]
    assert sorted(rows, key=lambda row: row["id"]) == [{"id": i, "v": i} for i in range(2, 10)]


def test_http_btree_lifecycle_and_kind_validation(tmp_path):
    database = LocalDatabase(tmp_path)
    with TestClient(create_app(database)) as client:
        assert client.post("/collections/demo", json={"dimension": 1}).status_code == 200
        populate(database.collection("demo"), [(1, 1), (2, 2)])
        url = "/collections/demo/json-indexes/tree"
        for kind in ("unknown", True, 2, None):
            assert client.put(url, json={"column": "data", "path": "v", "kind": kind}).status_code == 422
        assert client.put(url, json={"column": "data", "path": "v", "kind": "btree"}).status_code == 200
        assert client.get("/collections/demo/json-indexes").json()["indexes"][0]["kind"] == "btree"
        query = {"expression": leaf(), "indexes": ["tree"]}
        assert client.post("/collections/demo/json-query", json=query).json() == {"ids": [2]}
        assert client.post(url + "/rebuild").json() == {"rebuilt": True}
        assert client.delete("/collections/demo").status_code == 200
        assert client.post("/collections/demo", json={"dimension": 1}).status_code == 200
        assert client.post("/collections/demo/json-query", json=query).json() == {"ids": [2]}
        assert client.delete(url).json() == {"dropped": True}
        assert client.get("/collections/demo/json-indexes").json() == {"indexes": []}


def test_btree_manifest_recovery_boundaries_and_backup(tmp_path):
    source, backup, restored = (tmp_path / p for p in ("source", "backup", "restored"))
    with closing(Collection(source, 1)) as db:
        populate(db, [(1, 1), (2, 2)])
        db.flush()
        old = (source / "manifest.bin").read_bytes()
        db.create_json_index("tree", "data", "v", kind="btree")
        created = (source / "manifest.bin").read_bytes()
        backup_collection(db, backup)
        db.drop_json_index("tree")
        dropped = (source / "manifest.bin").read_bytes()
    restore_storage(backup, restored, 1)
    with closing(Collection(restored, 1)) as db:
        assert db.json_indexes()[0]["kind"] == "btree"
        assert db.query_json(leaf(), indexes=["tree"]) == [2]
    for operation, before, after, prior, following in [
        ("create", old, created, [], ["tree"]), ("drop", created, dropped, ["tree"], []),
    ]:
        for boundary, temporary in enumerate((b"", after[:len(after)//2], after, None)):
            path = tmp_path / f"{operation}-{boundary}"
            shutil.copytree(source, path)
            (path / "manifest.bin").write_bytes(after if temporary is None else before)
            if temporary is not None:
                (path / "manifest.bin.tmp").write_bytes(temporary)
            with closing(Collection(path, 1)) as db:
                names = following if temporary is None else prior
                assert [item["name"] for item in db.json_indexes()] == names
                assert db.query_json(leaf(), indexes=names) == [2]
    # A valid temporary manifest cannot rescue a corrupt committed manifest.
    (restored / "manifest.bin.tmp").write_bytes(created)
    (restored / "manifest.bin").write_bytes(created[:-1])
    with pytest.raises(ValidationError):
        Collection(restored, 1)


@pytest.mark.parametrize("kind", ["unknown", "", True, 2, None])
def test_invalid_native_kind_cannot_publish_catalog(tmp_path, kind):
    with closing(Collection(tmp_path, 1)) as db:
        populate(db, [(1, 1)])
        with pytest.raises(ValidationError):
            db.create_json_index("tree", "data", "v", kind=kind)
        assert db.json_indexes() == []
        db.create_json_index("tree", "data", "v", kind="btree")
