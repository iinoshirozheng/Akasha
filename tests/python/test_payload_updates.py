from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import json
from pathlib import Path

import pytest

from akashadb import Collection, PointMutation, ResourceLimits, VectorField


ALL = {"kind": "all", "children": []}


def payload(db, point=1):
    return {field.name: field.value for field in db.get_point(point).fields}


def condition(name, value):
    return {"kind": "condition", "name": name, "operator": "eq", "type": "int", "value": value}


def test_public_mutations_match_all_supported_source_roots(tmp_path):
    fixture = Path(__file__).parents[1] / "fixtures/qdrant-payload-values/values.json"
    valid = lambda obj: all(key and "\0" not in key for key in obj)
    count = 0
    with closing(Collection(tmp_path, 1, vectors={})) as db:
        db.apply_point_batch([PointMutation.upsert(1)])
        for case in json.loads(fixture.read_text())["cases"]:
            if case["op"] == "get" or not valid(case["input"]) or not valid(case["output"]):
                continue
            if case["op"] == "set" and case["path"] is None and not valid(case["source"]):
                continue
            db.overwrite_payload(case["input"], points=[1])
            if case["op"] == "set":
                result = db.set_payload(case["source"], points=[1], key=case["path"])
            else:
                result = db.delete_payload([case["path"]], points=[1])
            assert result.count == 1
            # JSON text also checks insertion order, int/float and signed zero.
            assert json.dumps(payload(db), ensure_ascii=False) == json.dumps(case["output"], ensure_ascii=False), count
            count += 1
    assert count == 1644


@pytest.mark.parametrize("flush", [False, True])
def test_payload_edits_preserve_every_vector_and_reopen(tmp_path, flush):
    schema = {
        "f16": VectorField(2, dtype="f16"),
        "bits": VectorField(9, dtype="binary", kind="binary", metric="hamming"),
        "multi": VectorField(2, kind="multivector"),
        "sparse": VectorField(0, kind="sparse", metric="dot"),
    }
    with closing(Collection(tmp_path, 2, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(1, vector=[1, 2], vectors={
            "f16": [0.5, -0.0], "bits": bytes([3, 1]), "multi": [[1, 2], [3, 4]],
            "sparse": [{"term_id": 9, "weight": 0.25}],
        })])
        original = db.get_point(1)
        db.overwrite_payload({"a": [{"v": 1}, {"v": 2}], "keep": None}, points=[1])
        db.set_payload({"v": None, "": 3, "nul\0key": 4}, points=[1], key="a[]")
        db.delete_payload(["a[0]", 'a[].""'], points=[1])
        assert payload(db) == {"a": [{"nul\0key": 4}, {"nul\0key": 4}], "keep": None}
        current = db.get_point(1)
        assert current.vectors == original.vectors
        assert current.vector == original.vector
        if flush:
            db.flush()
    with closing(Collection(tmp_path, 2)) as reopened:
        assert reopened.get_point(1).vectors == original.vectors
        assert payload(reopened)["a"] == [{"nul\0key": 4}, {"nul\0key": 4}]
        reopened.clear_payload(points=[1])
        assert payload(reopened) == {}
        assert reopened.get_point(1).vectors == original.vectors


def test_selectors_precedence_duplicates_empty_and_snapshot(tmp_path):
    from akashadb.arrow import scan_record_batches

    with closing(Collection(tmp_path, 1)) as db:
        for i in [3, 1, 2]:
            db.upsert(i, [i])
            db.overwrite_payload({"group": 1, "array": [1, None]}, points=[i])
        scanner = scan_record_batches(db, columns=("id",), payload_schema={"group": "int"})
        result = db.set_payload({"group": 2}, filter=condition("array", 1))
        assert result.count == 3
        assert [db.get_point(i).sequence for i in [1, 2, 3]] == list(range(result.first_sequence, result.last_sequence + 1))
        assert [row["payload.group"] for batch in scanner for row in batch.to_pylist()] == [1, 1, 1]
        result = db.clear_payload(points=[1, 1], filter=condition("group", 999))
        assert result.count == 1
        assert payload(db) == {}
        assert payload(db, 2)["group"] == 2
        before = db.last_sequence
        for result in (db.clear_payload(points=[], filter=ALL), db.clear_payload(filter=condition("group", 999))):
            assert (result.first_sequence, result.last_sequence, result.count) == (0, before, 0)


@pytest.mark.parametrize("operation", ["set", "overwrite", "delete", "clear"])
def test_missing_target_rejects_whole_operation(tmp_path, operation):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1])
        db.overwrite_payload({"keep": 1}, points=[1])
        before = (tmp_path / "wal.bin").read_bytes()
        seq = db.last_sequence
        method = getattr(db, operation + "_payload")
        args = ({"new": 2},) if operation in ("set", "overwrite") else (["keep"],) if operation == "delete" else ()
        with pytest.raises(Exception, match="does not exist"):
            method(*args, points=[1, 404])
        assert payload(db) == {"keep": 1}
        assert db.get_point(404) is None
        assert db.last_sequence == seq
        assert (tmp_path / "wal.bin").read_bytes() == before


def test_all_prepared_replacements_validate_before_wal_append(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1])
        db.upsert(2, [2])
        db.overwrite_payload({f"key{i}": i for i in range(1024)}, points=[2])
        before = (tmp_path / "wal.bin").read_bytes()
        with pytest.raises(Exception, match="field count"):
            db.set_payload({"new": True}, points=[1, 2])
        assert payload(db) == {}
        assert len(payload(db, 2)) == 1024
        assert (tmp_path / "wal.bin").read_bytes() == before


@pytest.mark.parametrize("selector", [{"points": [1, 2, 3]}, {"filter": ALL}])
def test_payload_target_budget_rejects_without_partial_changes(tmp_path, selector):
    with closing(Collection(tmp_path, 1, limits=ResourceLimits(max_batch_rows=2))) as db:
        for i in range(1, 4):
            db.upsert(i, [i])
        before = db.last_sequence
        with pytest.raises(Exception, match="resource limit"):
            db.set_payload({"new": 1}, **selector)
        assert db.last_sequence == before
        assert all(payload(db, i) == {} for i in range(1, 4))


def test_maximum_depth_and_atomic_torn_payload_batch(tmp_path):
    deep = None
    for _ in range(64):
        deep = [deep]
    with closing(Collection(tmp_path, 1)) as db:
        for i in (1, 2):
            db.upsert(i, [i])
        db.set_payload({"deep": deep}, points=[1, 2])
        db.set_payload({"keep": 1}, points=[1, 2])
        db.flush()
        db.overwrite_payload({"replaced": True}, points=[1, 2])
    wal = (tmp_path / "wal.bin").read_bytes()
    (tmp_path / "wal.bin").write_bytes(wal[:-1])
    with closing(Collection(tmp_path, 1)) as db:
        assert payload(db, 1) == payload(db, 2) == {"deep": deep, "keep": 1}
        db.delete_payload(["deep"], points=[1, 2])
        assert payload(db) == {"keep": 1}


@pytest.mark.parametrize("stage", ["points", "filter"])
def test_conversion_close_is_checked_before_mutation(tmp_path, stage):
    db = Collection(tmp_path, 1)
    db.upsert(1, [1])
    before = (tmp_path / "wal.bin").read_bytes()

    class ClosingList(list):
        def __iter__(self):
            db.close()
            return super().__iter__()

    class ClosingNumber:
        def __int__(self):
            db.close()
            return 1
        __index__ = __int__

    selector = {"points": ClosingList([1])} if stage == "points" else {"filter": condition("value", ClosingNumber())}
    with pytest.raises(Exception, match="closed"):
        db.set_payload({"x": 1}, **selector)
    assert (tmp_path / "wal.bin").read_bytes() == before


def test_concurrent_disjoint_payload_merges_retain_all_updates(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1])
        def write(worker):
            for iteration in range(10):
                db.set_payload({f"worker{worker}": iteration}, points=[1])
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(write, range(4)))
        assert payload(db) == {f"worker{i}": 9 for i in range(4)}


def test_invalid_payload_mutation_inputs(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1])
        db.set_payload({"x": 1}, points=[1])
        before = db.last_sequence
        invalid = [
            lambda: db.clear_payload(),
            lambda: db.set_payload([], points=[1]),
            lambda: db.set_payload({1: "bad"}, points=[1]),
            lambda: db.set_payload({"x": float("nan")}, points=[1]),
            lambda: db.set_payload({"": 1}, points=[1]),
            lambda: db.set_payload({"x": 1}, points=[1], key="a["),
            lambda: db.clear_payload(points=[True]),
            lambda: db.clear_payload(points={1: True}),
            lambda: db.delete_payload("x", points=[1]),
            lambda: db.delete_payload(["a["] , points=[1]),
            lambda: db.delete_payload(["a"] * 1025, points=[1]),
        ]
        for operation in invalid:
            with pytest.raises(Exception):
                operation()
        assert db.last_sequence == before
        assert payload(db) == {"x": 1}


def test_untrusted_iterator_lengths_do_not_bypass_mutation_budgets(tmp_path):
    class WrongLength(list):
        def __len__(self):
            return 0

    with closing(Collection(tmp_path, 1, limits=ResourceLimits(max_batch_rows=1))) as db:
        db.upsert(1, [1])
        before = db.last_sequence
        with pytest.raises(Exception, match="resource limit"):
            db.clear_payload(points=WrongLength([1, 1]))
        with pytest.raises(Exception, match="path count"):
            db.delete_payload(WrongLength(["x"] * 1025), points=[1])
        assert db.last_sequence == before


def test_http_payload_mutations(tmp_path):
    from fastapi.testclient import TestClient
    from akashadb import LocalDatabase
    from apps.server.main import create_app

    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        assert client.post("/collections/demo", json={"dimension": 1}).status_code == 200
        assert client.post("/collections/demo/points", json={"id": 1, "vector": [1]}).status_code == 200
        url = "/collections/demo/points/payload"
        for method, suffix, body in [
            ("put", "", {"payload": {"a": [{"x": 1}], "keep": None}}),
            ("post", "", {"payload": {"x": None, "z": 3}, "key": "a[]"}),
            ("post", "/delete", {"keys": ["a[].z"]}),
        ]:
            response = getattr(client, method)(url + suffix, json=dict(body, points=[1]))
            assert response.status_code == 200, response.text
            assert response.json()["count"] == 1
        document = client.get("/collections/demo/points/1").json()
        assert {f["name"]: f["value"] for f in document["fields"]} == {"a": [{}], "keep": None}
        assert document["vector"] == [1]
        assert client.post(url + "/clear", json={"filter": ALL}).json()["count"] == 1
        assert client.get("/collections/demo/points/1").json()["fields"] == []
        assert client.post(url + "/clear", json={"points": [True]}).status_code == 422
