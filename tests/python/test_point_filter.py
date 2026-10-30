"""Source point/path conditions through public queries, storage and services."""
from contextlib import closing
from dataclasses import replace
import json
from pathlib import Path

import pytest

from akashadb import (Collection, CollectionConfig, Formula, IvfOptions, PointMutation,
                     QueryRequest, SearchRequest, SparseElement, ValidationError, VectorField)
from akashadb.arrow import (query_record_batch, scan_record_batches, search_record_batch,
                           search_field_record_batch)
from test_formula_payload import field


CASES = json.loads((Path(__file__).parents[1]/"fixtures/qdrant-point-filter/filters.json").read_text())["cases"]


def ids(hits):
    return [hit.id for hit in hits]


def has_vector(name):
    return dict(kind="has_vector",name=name)


def test_public_source_conditions_and_arrow(tmp_path):
    schema = {"v":VectorField(1,metric="dot"),"中文":VectorField(1,metric="dot"),
              "sparse":VectorField(0,kind="sparse",metric="dot")}
    with closing(Collection(tmp_path,1,vectors=schema)) as db:
        previous = None
        for i,case in enumerate(CASES):
            # Missing tracker context and hash-only cases are covered natively.
            if case["id"] is None or "hash_bytes" in case:
                continue
            point_id=case["id"]
            mutations=[] if previous in (None,point_id) else [PointMutation.delete(previous)]
            named={name: ([] if name=="sparse" else [1]) for name in case["vectors"] if name}
            options={"vector":[1]} if "" in case["vectors"] else {}
            mutations.append(PointMutation.upsert(point_id,vectors=named,fields=[
                field(k,v) for k,v in case["payload"].items()],**options))
            db.apply_point_batch(mutations)
            previous=point_id
            request=QueryRequest(filter=case["filter"])
            if "error" in case:
                with pytest.raises(ValidationError):db.query(request)
                with pytest.raises(ValidationError):query_record_batch(db,request)
            else:
                expected=[point_id] if case["matches"] else []
                assert ids(db.query(request))==expected,i
                assert query_record_batch(db,request)["id"].to_pylist()==expected,i


@pytest.mark.parametrize("checkpoint",[False,True])
def test_vector_presence_is_independent_of_empty_values_and_searchability(tmp_path,checkpoint):
    schema={"s":VectorField(0,kind="sparse",metric="dot"),
            "multi":VectorField(1,kind="multivector",metric="dot"),
            "v":VectorField(1,metric="dot")}
    db=Collection(tmp_path,1,vectors=schema)
    db.apply_point_batch([
        PointMutation.upsert(-1,vector=[1],sparse=[],vectors={"s":[],"multi":[],"v":[1]}),
        PointMutation.upsert(2,vector=[2],vectors={"v":[2]}),
        PointMutation.upsert(3,vectors={"s":[SparseElement(7,3)]}),
        PointMutation.upsert(4),
    ])
    assert ids(db.query(QueryRequest(filter=has_vector(""))))==[-1,2]
    assert ids(db.query(QueryRequest(filter=dict(kind="has_vector",field_id=1))))==[-1]
    assert ids(db.query(QueryRequest(filter=has_vector("s"))))==[-1,3]
    assert ids(db.query(QueryRequest(filter=has_vector("multi"))))==[-1]
    assert db.query(QueryRequest(filter=has_vector("unknown")))==[]
    scanner=scan_record_batches(db,columns=("id",),filter=has_vector("s"))
    if checkpoint:db.flush()
    db.apply_point_batch([PointMutation.update(-1,vectors={"s":None,"multi":None},sparse=None)])
    assert db.set_payload({"found":True},filter=has_vector("s")).count==1
    assert ids(db.query(QueryRequest(filter=has_vector("s"))))==[3]
    assert ids(db.query(QueryRequest(filter=has_vector("multi"))))==[]
    assert [r["id"] for b in scanner for r in b.to_pylist()]==[-1,3]
    db.close()
    with closing(Collection(tmp_path,1)) as reopened:
        assert ids(reopened.query(QueryRequest(filter=has_vector("s"))))==[3]
        assert reopened.query(QueryRequest(filter=dict(kind="has_vector",field_id=1)))==[]
        assert reopened.clear_payload(filter=has_vector("s")).count==1
        reopened.flush()


def test_id_vector_filters_reach_exact_hnsw_ivf_sparse_batch_and_formula(tmp_path):
    config=CollectionConfig(2,ann_metric="dot",m=32,m0=64,ef_construction=128)
    schema={"v":VectorField(2,metric="dot",hnsw=config),
            "marker":VectorField(0,kind="sparse",metric="dot"),
            "s":VectorField(0,kind="sparse",metric="dot")}
    with closing(Collection(tmp_path,2,vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i,vector=[i,1],sparse=[SparseElement(7,i+1)],
            vectors={"v":[i,1],"s":[SparseElement(7,i+1)],**({"marker":[]} if i%2 else {})},
            fields=[field("items",[{}])]) for i in range(128)])
        filt=dict(kind="all",children=[has_vector("marker"),dict(kind="has_id",ids=list(range(120,128)))])
        request=QueryRequest("nearest","v",target=[1,0],limit=3,filter=filt)
        assert ids(db.query(request))==[127,125,123]
        assert db.query(replace(request,mode="approx",ef_search=128))==db.query(request)
        for mode,options in [("exact",{}),("approx",{"ef_search":128}),
                             ("ivf",{"ivf":IvfOptions(4,4)})]:
            assert ids(db.search_field("v",[1,0],3,filter=filt,mode=mode,**options))==[127,125,123]
            assert search_field_record_batch(db,"v",[1,0],3,filter=filt,mode=mode,**options)["id"].to_pylist()==[127,125,123]
        assert ids(db.search_field("s",[SparseElement(7,1)],3,filter=filt))==[127,125,123]
        dense=SearchRequest("dot",3,vector=[1,0],filter=filt)
        assert ids(db.search(dense))==[127,125,123]
        assert search_record_batch(db,dense)["id"].to_pylist()==[127,125,123]
        assert ids(db.search(replace(dense,mode="approx",ef_search=128)))==[127,125,123]
        sparse=SearchRequest("dot",3,sparse=[SparseElement(7,1)],mode="sparse",filter=filt)
        assert ids(db.search(sparse))==[127,125,123]
        assert ids(db.search(replace(dense,mode="hybrid",sparse=[SparseElement(7,1)])))==[127,125,123]
        batch=db.search_batch("dot",[[1,0],[1,0]],3,num_workers=2,filters=[filt,filt])
        assert [ids(h) for h in batch]==[[127,125,123],[127,125,123]]
        formula=QueryRequest("formula",prefetch=(replace(request,filter=None),),filter=filt,
            formula=Formula({"sum":["$score",{"condition":has_vector("marker")},
                {"condition":dict(kind="has_id",ids=[127])}]}),limit=3)
        assert query_record_batch(db,formula).to_pydict()=={"id":[127,125,123],"score":[129,126,124]}
        nested=dict(kind="nested",key="items",filter=dict(kind="not",child=has_vector("marker")))
        assert ids(db.query(replace(request,filter=nested)))==[127,126,125]
        db.flush()


def test_whole_path_empty_and_null_are_distinct_from_field_any(tmp_path):
    with closing(Collection(tmp_path,1)) as db:
        db.upsert(1,[1],[field("items",[{"x":None},{"x":7}]),field("a",[None])])
        assert db.query(QueryRequest(filter=dict(kind="is_empty",key="items[].x")))==[]
        assert ids(db.query(QueryRequest(filter=dict(kind="field",key="items[].x",is_empty=True))))==[1]
        assert db.query(QueryRequest(filter=dict(kind="is_null",key="a")))==[]
        assert ids(db.query(QueryRequest(filter=dict(kind="is_null",key="a[]"))))==[1]


@pytest.mark.parametrize("case",[c for c in CASES if "error" in c])
def test_invalid_point_conditions_before_writes_and_without_candidates(tmp_path,case):
    with closing(Collection(tmp_path,1)) as db:
        before=db.last_sequence
        with pytest.raises(ValidationError):db.set_payload({"x":1},filter=case["filter"])
        with pytest.raises(ValidationError):db.query(QueryRequest(filter=case["filter"]))
        assert db.last_sequence==before


def test_point_filter_existing_http_routes(tmp_path):
    from fastapi.testclient import TestClient
    from akashadb import LocalDatabase
    from apps.server.main import create_app
    with TestClient(create_app(LocalDatabase(tmp_path))) as client:
        assert client.post("/collections/demo",json={"dimension":1}).status_code==200
        for id in [1,2]:
            assert client.post("/collections/demo/points",json={"id":id,"vector":[id]}).status_code==200
        filt=dict(kind="all",children=[has_vector(""),dict(kind="has_id",ids=[1])])
        response=client.post("/collections/demo/search",json={"metric":"dot","vector":[1],"k":10,"filter":filt})
        assert response.status_code==200,response.text
        assert [h["id"] for h in response.json()]==[1]
        response=client.post("/collections/demo/points/payload",json={"payload":{"found":True},"filter":filt})
        assert response.status_code==200,response.text
        assert response.json()["count"]==1


def test_native_signed_ids_and_invalid_extensions(tmp_path):
    with closing(Collection(tmp_path,1)) as db:
        db.upsert(-1,[1])
        assert ids(db.query(QueryRequest(filter=dict(kind="has_id",ids=[-1,-1]))))==[-1]
        for filt in [dict(kind="has_id",ids=[2**63]),dict(kind="has_id",ids=["550e8400-e29b-41d4-a716-446655440000"]),
                     dict(kind="has_vector",field_id=-1),dict(kind="has_vector",field_id=2**32),
                     dict(kind="has_vector",name="",field_id=0),dict(kind="has_vector"),
                     dict(kind="slice",total=1,index=0,extra=True)]:
            with pytest.raises(ValidationError):db.query(QueryRequest(filter=filt))
