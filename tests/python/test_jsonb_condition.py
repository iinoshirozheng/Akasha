"""Source JSONB booleans composed with collection query/update contracts."""
from contextlib import closing
from dataclasses import replace
import json
from pathlib import Path

import pytest

from akashadb import (Collection, CollectionConfig, Formula, IvfOptions, JsonbValue,
                     PayloadField, PointMutation, QueryRequest, SearchRequest,
                     SparseElement, ValidationError, VectorField)
from akashadb.arrow import (query_record_batch, scan_record_batches, search_record_batch,
                           search_field_record_batch)


def condition(function="predicate_match", argument="$.yes == true", **options):
    return dict(kind="jsonb", key="data", function=function, argument=argument, **options)


def payload(text):
    return PayloadField("data", "jsonb", JsonbValue.from_json(text))


def ids(hits):
    return [hit.id for hit in hits]


def test_jsonb_filters_reach_search_scan_formula_and_arrow(tmp_path):
    config = CollectionConfig(2, ann_metric="dot", m=32, m0=64, ef_construction=128)
    schema = {"v": VectorField(2, metric="dot", hnsw=config),
              "s": VectorField(0, kind="sparse", metric="dot")}
    with closing(Collection(tmp_path, 2, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i, vector=[i, 1],
            sparse=[SparseElement(7, i+1)], vectors={"v": [i, 1], "s": [SparseElement(7, i+1)]},
            fields=[payload(json.dumps({"yes": bool(i % 2), "n": i}))]) for i in range(128)])
        filt = condition(argument="$.yes == true && $.n >= 120")
        request = QueryRequest("nearest", "v", target=[1, 0], limit=3, filter=filt)
        expected = [127, 125, 123]
        assert ids(db.query(request)) == expected
        assert db.query(replace(request, mode="approx", ef_search=128)) == db.query(request)
        assert query_record_batch(db, request)["id"].to_pylist() == expected
        for mode, options in [("exact", {}), ("approx", {"ef_search": 128}),
                              ("ivf", {"ivf": IvfOptions(4, 4)})]:
            assert ids(db.search_field("v", [1, 0], 3, filter=filt, mode=mode, **options)) == expected
            assert search_field_record_batch(db, "v", [1, 0], 3, filter=filt, mode=mode, **options)["id"].to_pylist() == expected
        assert ids(db.search_field("s", [SparseElement(7, 1)], 3, filter=filt)) == expected
        dense = SearchRequest("dot", 3, vector=[1, 0], filter=filt)
        for request in [dense, replace(dense, mode="approx", ef_search=128),
                        SearchRequest("dot", 3, sparse=[SparseElement(7, 1)], mode="sparse", filter=filt),
                        replace(dense, mode="hybrid", sparse=[SparseElement(7, 1)])]:
            assert ids(db.search(request)) == expected
            assert search_record_batch(db, request)["id"].to_pylist() == expected
        assert [ids(hits) for hits in db.search_batch("dot", [[1, 0], [1, 0]], 3,
                    num_workers=2, filters=[filt, filt])] == [expected, expected]
        formula = QueryRequest("formula", prefetch=(QueryRequest("nearest", "v", target=[1, 0], limit=128),),
            formula=Formula({"sum": ["$score", {"condition": filt}]}), filter=filt, limit=3)
        assert query_record_batch(db, formula).to_pydict() == {"id": expected, "score": [128, 126, 124]}
        assert [row["id"] for batch in scan_record_batches(db, columns=("id",), filter=filt)
                for row in batch.to_pylist()] == [121, 123, 125, 127]


def test_missing_null_nested_and_outer_boolean_contract(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        doc = JsonbValue.from_json('{yes:"YES",n:null,items:[1,2],"":true}')
        db.apply_point_batch([PointMutation.upsert(1),
            PointMutation.upsert(2, fields=[PayloadField("data", "null", None)]),
            PointMutation.upsert(3, fields=[PayloadField("data", "jsonb", doc)]),
            PointMutation.upsert(4, fields=[PayloadField("data", "jsonb", JsonbValue.from_json("null"))]),
            PointMutation.upsert(5, fields=[PayloadField("items", "array", [{"data": doc}])])])
        for function, arg, expected in [("predicate_match", "$", []),
                ("json_exists", "$.yes == false", [3, 4]),
                ("json_exists", "$.n", [3]), ("json_get_bool", "yes", [3]),
                ("json_get_bool", "n", []), ("json_get_bool", "", [3])]:
            assert ids(db.query(QueryRequest(filter=condition(function, arg)))) == expected
        filt = condition("json_array_contains", "$.items", needle="2")
        assert ids(db.query(QueryRequest(filter=filt))) == [3]
        assert ids(db.query(QueryRequest(filter=dict(kind="not", child=filt)))) == [1, 2, 4, 5]
        nested = dict(kind="nested", key="items", filter=condition("json_get_bool", "yes"))
        assert ids(db.query(QueryRequest(filter=nested))) == [5]
        wildcard = {**condition("json_get_bool", "yes"), "key": "items[].data"}
        assert ids(db.query(QueryRequest(filter=wildcard))) == [5]
        assert ids(db.query(QueryRequest(filter=dict(kind="at_least", min_count=1, children=[filt, nested])))) == [3, 5]


@pytest.mark.parametrize("flush", [False, True])
def test_snapshot_reopen_and_atomic_conditional_mutations(tmp_path, flush):
    db = Collection(tmp_path, 1)
    db.apply_point_batch([PointMutation.upsert(i, vector=[i], fields=[payload('{yes:true}')]) for i in (1, 2)])
    filt = condition()
    scanner = scan_record_batches(db, columns=("id",), filter=filt, batch_size=1)
    db.set_payload({"data": JsonbValue.from_json('{yes:false}')}, points=[2])
    assert db.set_payload({"selected": True}, filter=filt).count == 1
    assert ids(db.query(QueryRequest(filter=filt))) == [1]
    assert [row["id"] for batch in scanner for row in batch.to_pylist()] == [1, 2]
    if flush:
        db.flush()
    db.close()
    with closing(Collection(tmp_path, 1)) as db:
        assert ids(db.query(QueryRequest(filter=filt))) == [1]
        db.set_payload({"data": "wrong type"}, points=[2])
        before = [db.get(i) for i in (1, 2)]
        wal = (tmp_path / "wal.bin").read_bytes()
        sequence = db.last_sequence
        with pytest.raises(ValidationError, match="JSONB payload"):
            db.set_payload({"must_not_commit": True}, filter=filt)
        with pytest.raises(ValidationError, match="JSONB payload"):
            db.query(QueryRequest(filter=filt))
        assert [db.get(i) for i in (1, 2)] == before
        assert db.last_sequence == sequence
        assert (tmp_path / "wal.bin").read_bytes() == wal
        db.delete_payload(["data"], points=[2])
        assert db.delete_payload(["selected"], filter=filt).count == 1
        assert db.overwrite_payload({"data": JsonbValue.from_json('{yes:true}')}, filter=filt).count == 1
        assert db.clear_payload(filter=filt).count == 1
        assert db.query(QueryRequest(filter=filt)) == []


INVALID = [condition(function="unknown"), condition(argument="$["),
           condition(function="json_array_contains"), condition(needle="extra"),
           condition(max_work=0), condition(max_work=True), condition(max_bytes=2**63),
           condition(max_results=1.0), condition(argument=None), condition(extra=True),
           {**condition(), "key": 1}, {**condition(), "needle": None},
           condition("json_get_bool", "x" * 65_537)]


@pytest.mark.parametrize("filt", INVALID)
def test_invalid_configuration_is_eager_on_empty_collection(tmp_path, filt):
    with closing(Collection(tmp_path, 1)) as db:
        before = db.last_sequence
        with pytest.raises(ValidationError):
            db.query(QueryRequest(filter=filt))
        with pytest.raises(ValidationError):
            db.set_payload({"x": 1}, filter=filt)
        with pytest.raises(ValidationError):
            list(scan_record_batches(db, columns=("id",), filter=filt))
        assert db.last_sequence == before


@pytest.mark.parametrize("option", ["max_work", "max_results", "max_bytes"])
def test_runtime_limits_reject_without_writes(tmp_path, option):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1], [payload("[1,2,3]")])
        filt = condition("json_exists", "$[*]", **{option: 1})
        before = db.last_sequence
        with pytest.raises(ValidationError, match="resource limit"):
            db.query(QueryRequest(filter=filt))
        with pytest.raises(ValidationError, match="resource limit"):
            db.clear_payload(filter=filt)
        assert db.last_sequence == before


def test_boolean_cast_errors_are_atomic(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.apply_point_batch([PointMutation.upsert(1, fields=[payload('{yes:true}')]),
                             PointMutation.upsert(2, fields=[payload('{yes:42}')])])
        sequence = db.last_sequence
        with pytest.raises(ValidationError, match="convert to boolean"):
            db.clear_payload(filter=condition("json_get_bool", "yes"))
        assert db.last_sequence == sequence
        assert all(db.get_point(i).fields for i in (1, 2))


def test_existing_http_search_and_conditional_mutations(tmp_path):
    from fastapi.testclient import TestClient
    from akashadb import LocalDatabase
    from apps.server.main import create_app
    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        assert client.post("/collections/demo", json={"dimension": 1}).status_code == 200
        for i, text in [(1, '{yes:true}'), (2, '{yes:false}')]:
            result = client.post("/collections/demo/points", json={"id": i, "vector": [i],
                "fields": [payload(text).to_wire()]})
            assert result.status_code == 200, result.text
        filt = condition()
        result = client.post("/collections/demo/search", json={"metric": "dot", "vector": [1], "k": 10, "filter": filt})
        assert result.status_code == 200, result.text
        assert [hit["id"] for hit in result.json()] == [1]
        result = client.post("/collections/demo/points/payload", json={"payload": {"selected": True}, "filter": filt})
        assert result.status_code == 200, result.text
        assert result.json()["count"] == 1
        result = client.post("/collections/demo/points/payload", json={"payload": {"x": 1}, "filter": condition(argument="$[")})
        assert result.status_code == 400, result.text


def test_indexed_search_preserves_row_short_circuit_and_error_order(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1], [PayloadField("data", "string", "bypass")])
        db.upsert(2, [2], [payload('{yes:true}')])
        bypass = dict(kind="condition", name="data", operator="eq", type="string", value="bypass")
        for filt, expected in [
            (dict(kind="any", children=[bypass, condition()]), [1, 2]),
            (dict(kind="all", children=[dict(kind="not", child=bypass), condition()]), [2]),
        ]:
            assert ids(db.query(QueryRequest(filter=filt))) == expected
            assert [r["id"] for batch in scan_record_batches(db, columns=("id",), filter=filt)
                    for r in batch.to_pylist()] == expected
            assert set(ids(db.search(SearchRequest("dot", 10, vector=[1], filter=filt)))) == set(expected)
            assert db.set_payload({"hit": True}, filter=filt).count == len(expected)
        for kind in ("any", "all"):
            filt = dict(kind=kind, children=[condition(), bypass])
            with pytest.raises(ValidationError, match="JSONB payload"):
                db.search(SearchRequest("dot", 10, vector=[1], filter=filt))
