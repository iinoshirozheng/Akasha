"""Source payload predicates through real collection/query/Arrow/HTTP paths."""
from contextlib import closing
from dataclasses import replace
import json
from pathlib import Path

import pytest

from akashadb import (Collection, CollectionClosedError, CollectionConfig, Formula, PointMutation,
                     QueryRequest, SearchRequest, ValidationError, VectorField)
from akashadb.arrow import query_record_batch, scan_record_batches, search_record_batch
from test_formula_payload import field


FIXTURE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-payload-filter/filters.json").read_text())


def predicate(key="a", **kwargs):
    return dict(kind="field", key=key, **kwargs)


def ids(hits):
    return [hit.id for hit in hits]


def test_public_source_cases_and_arrow(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        for i, case in enumerate(FIXTURE["cases"]):
            db.apply_point_batch([PointMutation.upsert(1, vector=[1], fields=[
                field(k, v) for k, v in case["payload"].items()])])
            request = SearchRequest("dot", 1, vector=[1], filter=case["filter"])
            if "error" in case:
                with pytest.raises(ValidationError):
                    db.search(request)
            else:
                expected = [1] if case["matches"] else []
                assert ids(db.search(request)) == expected, i
                assert search_record_batch(db, request)["id"].to_pylist() == expected, i


def nested_filter():
    return dict(kind="nested", key="items", filter=dict(kind="all", children=[
        predicate("color", match={"value":"red"}), predicate("stock", range={"gt":0})]))


@pytest.mark.parametrize("checkpoint", [False, True])
def test_nested_selection_mutation_snapshot_scan_and_restart(tmp_path, checkpoint):
    db = Collection(tmp_path, 1)
    for i, items in [(1, [{"color":"red","stock":0},{"color":"blue","stock":2}]),
                     (2, [{"color":"red","stock":2}]), (3, [{"color":"red","stock":3}])]:
        db.upsert(i, [i], [field("items", items)])
    filt = nested_filter()
    request = SearchRequest("dot", 10, vector=[1], filter=filt)
    assert ids(db.search(request)) == [3, 2]
    scanner = scan_record_batches(db, columns=("id",), filter=filt)
    assert db.set_payload({"selected":True}, filter=filt).count == 2
    assert "selected" not in {f.name for f in db.get(1).fields}
    assert db.set_payload({"stock":0}, points=[3], key="items[]").count == 1
    assert ids(db.search(request)) == [2]
    assert [row["id"] for batch in scanner for row in batch.to_pylist()] == [2, 3]
    saved = search_record_batch(db, request)
    if checkpoint:
        db.flush()
    db.close()
    assert saved["id"].to_pylist() == [2]
    with closing(Collection(tmp_path, 1)) as reopened:
        assert ids(reopened.search(request)) == [2]
        assert reopened.clear_payload(filter=filt).count == 1
        assert reopened.search(request) == []


def test_new_predicates_in_named_hnsw_prefetch_and_formula(tmp_path):
    config = CollectionConfig(2, ann_metric="dot", m=32, m0=64, ef_construction=128)
    with closing(Collection(tmp_path, 2, vectors={"v":VectorField(2,metric="dot",hnsw=config)})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vector=[i, 1], vectors={"v":[i,1]},
            fields=[field("items",[{"color":"red" if i % 2 else "blue","stock":i}])]) for i in range(128)])
        filt = nested_filter()
        exact = QueryRequest("nearest", "v", target=[1,0], limit=5, filter=filt)
        assert ids(db.query(exact)) == [127,125,123,121,119]
        assert db.query(replace(exact,mode="approx",ef_search=128)) == db.query(exact)
        request = QueryRequest("formula", prefetch=(replace(exact,filter=None),), filter=filt,
            formula=Formula({"sum":["$score",{"condition":filt}]}), limit=3)
        assert ids(db.query(request)) == [127,125,123]
        assert query_record_batch(db,request)["score"].to_pylist() == [128,126,124]
        minimum = dict(kind="at_least",min_count=1,children=[filt,predicate("items",is_null=True)])
        assert db.query(replace(exact,filter=minimum)) == db.query(exact)


def test_literal_names_and_nested_path_names_remain_distinct(tmp_path):
    with closing(Collection(tmp_path,1)) as db:
        db.upsert(1,[1],[field("a.b",1),field("a",{"b":2})])
        request = SearchRequest("dot",1,vector=[1])
        old = dict(kind="condition",name="a.b",operator="eq",type="int",value=1)
        for filt in [old, predicate("a.b",match={"value":2}),predicate('"a.b"',match={"value":1})]:
            assert ids(db.search(replace(request,filter=filt))) == [1]
        assert db.search(replace(request,filter=predicate("a.b",match={"value":1}))) == []


def test_full_depth_payload_path_and_parallel_batch(tmp_path):
    value = {"leaf":2}
    for _ in range(63):
        value = {"child":value}
    with closing(Collection(tmp_path,1)) as db:
        db.upsert(1,[1],[field("root",value)])
        path = "root." + "child."*63 + "leaf"
        keep = predicate(path,match={"value":2})
        reject = predicate(path,match={"value":3})
        batches = db.search_batch("dot",[[1],[1]],1,num_workers=2,filters=[keep,reject])
        assert [ids(hits) for hits in batches] == [[1],[]]
        assert db.set_payload({"checked":True},filter=keep).count == 1


@pytest.mark.parametrize("bad", [
    predicate(match={"value":2**63}), predicate(match={"any":[False]}),
    predicate(range={"gte":float("nan")}), predicate(is_empty="true"),
    predicate(geo_polygon={}), predicate(values_count={"lt":2**64}),
    dict(kind="at_least",children=[],min_count=True),
    dict(kind="nested",key=1,filter=dict(kind="all",children=[])),
])
def test_bad_filters_fail_before_write_even_on_empty_collection(tmp_path,bad):
    with closing(Collection(tmp_path,1)) as db:
        before = db.last_sequence
        with pytest.raises(ValidationError):
            db.set_payload({"x":1},filter=bad)
        assert db.last_sequence == before
        with pytest.raises(ValidationError):
            db.search(SearchRequest("dot",1,vector=[1],filter=bad))


def test_filter_resource_limits_and_conversion_owner_recheck(tmp_path):
    with closing(Collection(tmp_path,1)) as db:
        filt = predicate(match={"value":1})
        for _ in range(16):
            filt = dict(kind="nested",key="a",filter=filt)
        with pytest.raises(ValidationError,match="depth|limit"):
            db.search(SearchRequest("dot",1,vector=[1],filter=filt))
        huge = dict(kind="at_least",min_count=0,children=[predicate(is_null=True)]*256)
        with pytest.raises(ValidationError,match="node|limit"):
            db.search(SearchRequest("dot",1,vector=[1],filter=huge))
        class ClosingDict(dict):
            def __getitem__(self,key):
                if key == "kind":
                    db.close()
                return super().__getitem__(key)
        with pytest.raises(CollectionClosedError,match="closed"):
            db.search(SearchRequest("dot",1,vector=[1],filter=ClosingDict(dict(kind="nested",key="items",filter=predicate("x",is_null=True)))))


def test_existing_http_search_and_payload_mutations(tmp_path):
    from fastapi.testclient import TestClient
    from akashadb import LocalDatabase
    from apps.server.main import create_app

    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        assert client.post("/collections/demo",json={"dimension":1}).status_code == 200
        for i,value in [(1,1),(2,2)]:
            assert client.post("/collections/demo/points",json={"id":i,"vector":[i],
                "fields":[{"name":"a","type":"object","value":{"b":value}}]}).status_code == 200
        filt = predicate("a.b",range={"gt":1})
        response = client.post("/collections/demo/search",json={"metric":"dot","vector":[1],"k":10,"filter":filt})
        assert response.status_code == 200, response.text
        assert [h["id"] for h in response.json()] == [2]
        response = client.post("/collections/demo/points/payload",json={"payload":{"selected":True},"filter":filt})
        assert response.status_code == 200, response.text
        assert response.json()["count"] == 1
