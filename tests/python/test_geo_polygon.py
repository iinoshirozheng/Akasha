"""Source polygon behavior through native-backed search, mutation and HTTP."""
from contextlib import closing
from dataclasses import replace
import json
from pathlib import Path

import pytest

from akashadb import (Collection, CollectionConfig, Formula, PointMutation,
                     QueryRequest, SearchRequest, ValidationError, VectorField)
from akashadb.arrow import query_record_batch, scan_record_batches, search_record_batch
from test_formula_payload import field


CASES = json.loads((Path(__file__).parents[1]/"fixtures/qdrant-polygon/filters.json").read_text())["cases"]


def polygon():
    return {"exterior":{"points":[[-4,-4],[4,-4],[4,4],[-4,4],[-4,-4]]},
            "interiors":[{"points":[[-1,-1],[1,-1],[1,1],[-1,1],[-1,-1]]}]}


def predicate(key="place"):
    return dict(kind="field",key=key,geo_polygon=polygon())


def test_public_polygon_source_cases_and_arrow(tmp_path):
    with closing(Collection(tmp_path,1)) as db:
        for i,case in enumerate(CASES):
            db.apply_point_batch([PointMutation.upsert(1,vector=[1],fields=[
                field(k,v) for k,v in case["payload"].items()])])
            request=SearchRequest("dot",1,vector=[1],filter=case["filter"])
            if "error" in case:
                with pytest.raises(ValidationError):db.search(request)
                with pytest.raises(ValidationError):search_record_batch(db,request)
            else:
                expected=[1] if case["matches"] else []
                assert [h.id for h in db.search(request)]==expected,i
                assert search_record_batch(db,request)["id"].to_pylist()==expected,i


@pytest.mark.parametrize("checkpoint",[False,True])
def test_polygon_nested_mutation_snapshot_and_restart(tmp_path,checkpoint):
    db=Collection(tmp_path,1)
    for i,items in [(1,[{"place":{"lon":2,"lat":2},"active":True}]),
                    (2,[{"place":{"lon":0,"lat":0},"active":True}]),
                    (3,[{"place":{"lon":2,"lat":2},"active":False},
                        {"place":{"lon":0,"lat":0},"active":True}]),
                    (4,[{"place":{"lon":-2,"lat":-2},"active":True}])]:
        db.upsert(i,[i],[field("items",items)])
    filt=dict(kind="nested",key="items",filter=dict(kind="all",children=[
        predicate(),dict(kind="field",key="active",match={"value":True})]))
    request=SearchRequest("dot",10,vector=[1],filter=filt)
    assert [h.id for h in db.search(request)]==[4,1]
    scanner=scan_record_batches(db,columns=("id",),filter=filt)
    assert db.set_payload({"selected":True},filter=filt).count==2
    assert db.set_payload({"place":{"lon":4,"lat":0}},points=[4],key="items[]").count==1
    assert [h.id for h in db.search(request)]==[1]
    assert [r["id"] for b in scanner for r in b.to_pylist()]==[1,4]
    retained=search_record_batch(db,request)
    if checkpoint:db.flush()
    db.close()
    assert retained["id"].to_pylist()==[1]
    with closing(Collection(tmp_path,1)) as reopened:
        assert [h.id for h in reopened.search(request)]==[1]
        assert reopened.clear_payload(filter=filt).count==1
        assert reopened.search(request)==[]


def test_polygon_named_hnsw_prefetch_formula_and_parallel_batch(tmp_path):
    config=CollectionConfig(2,ann_metric="dot",m=32,m0=64,ef_construction=128)
    with closing(Collection(tmp_path,2,vectors={"v":VectorField(2,metric="dot",hnsw=config)})) as db:
        db.apply_point_batch([PointMutation.upsert(i,vector=[i,1],vectors={"v":[i,1]},
            fields=[field("place",{"lon":2 if i%2 else 0,"lat":2 if i%2 else 0})]) for i in range(128)])
        filt=predicate()
        request=QueryRequest("nearest","v",target=[1,0],limit=5,filter=filt)
        assert [h.id for h in db.query(request)]==[127,125,123,121,119]
        assert db.query(replace(request,mode="approx",ef_search=128))==db.query(request)
        formula=QueryRequest("formula",prefetch=(replace(request,filter=None),),filter=filt,
            formula=Formula({"sum":["$score",{"condition":filt}]}),limit=3)
        assert query_record_batch(db,formula).to_pydict()=={"id":[127,125,123],"score":[128,126,124]}
        reject=dict(kind="not",child=filt)
        batch=db.search_batch("dot",[[1,0],[1,0]],2,num_workers=2,filters=[filt,reject])
        assert [[h.id for h in hits] for hits in batch]==[[127,125],[126,124]]


@pytest.mark.parametrize("case",[c for c in CASES if "error" in c])
def test_polygon_invalid_query_rejected_before_mutation_and_without_candidates(tmp_path,case):
    with closing(Collection(tmp_path,1)) as db:
        before=db.last_sequence
        with pytest.raises(ValidationError):db.set_payload({"x":1},filter=case["filter"])
        assert db.last_sequence==before
        with pytest.raises(ValidationError):
            db.search(SearchRequest("dot",1,vector=[1],filter=case["filter"]))


def test_polygon_existing_http_paths(tmp_path):
    from fastapi.testclient import TestClient
    from akashadb import LocalDatabase
    from apps.server.main import create_app

    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        assert client.post("/collections/demo",json={"dimension":1}).status_code==200
        for i,xy in [(1,(0,0)),(2,(2,2)),(3,(4,4))]:
            assert client.post("/collections/demo/points",json={"id":i,"vector":[i],
                "fields":[{"name":"place","type":"object","value":{"lon":xy[0],"lat":xy[1]}}]}).status_code==200
        filt=predicate()
        response=client.post("/collections/demo/search",json={"metric":"dot","vector":[1],"k":10,"filter":filt})
        assert response.status_code==200,response.text
        assert [h["id"] for h in response.json()]==[2]
        response=client.post("/collections/demo/points/payload",json={"payload":{"selected":True},"filter":filt})
        assert response.status_code==200,response.text
        assert response.json()["count"]==1
