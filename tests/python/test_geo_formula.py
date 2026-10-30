"""Geographic formulas through real native-backed Python/Arrow queries."""
from contextlib import closing
from dataclasses import replace
import json
from pathlib import Path
import struct

import pytest

from akashadb import (CancellationToken, Collection, Formula, PayloadField,
                     PointMutation, QueryRequest, ValidationError)
from akashadb.arrow import query_record_batch
from test_formula_payload import field


FIXTURE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-geo/geo.json").read_text())


def geo(origin=None, to="location"):
    return {"geo_distance": {"origin": {"lon":0,"lat":0} if origin is None else origin, "to":to}}


def query(expression, defaults=None, **options):
    return QueryRequest("formula", prefetch=(QueryRequest(),), formula=Formula(expression, defaults or {}), **options)


def test_public_geo_formulas_match_original_qdrant_and_dependency(tmp_path):
    with closing(Collection(tmp_path,1)) as db:
        for i, case in enumerate(FIXTURE["formulas"]):
            db.apply_point_batch([PointMutation.upsert(1, fields=[field(k,v) for k,v in case["payload"].items()])])
            request = query(case["expression"],case["defaults"])
            if case["expected_bits"] is None:
                with pytest.raises(ValidationError):
                    db.query(request)
                with pytest.raises(ValidationError):
                    query_record_batch(db,request)
            else:
                hits = db.query(request)
                assert [hit.id for hit in hits] == [1], i
                assert struct.unpack("<I",struct.pack("<f",hits[0].score))[0] == case["expected_bits"], i
                assert query_record_batch(db,request).to_pydict() == {"id":[1],"score":[hits[0].score]}, i


@pytest.mark.parametrize("case",FIXTURE["points"])
def test_geo_origin_conversion_matches_qdrant_before_candidate_evaluation(tmp_path, case):
    # Invalid origins fail even when the expression would short-circuit and the
    # collection has no candidates; origin validation is a request-stage rule.
    with closing(Collection(tmp_path,1)) as db:
        expression = {"mult":[0,{"geo_distance":{"origin":case["input"],"to":"location"}}]}
        if "error" in case:
            with pytest.raises(ValidationError):
                db.query(query(expression))
        else:
            assert db.query(query(expression)) == []
            db.upsert(1,[1],[field("location",case["point"])])
            assert db.query(query(expression["mult"][1]))[0].score == 0


@pytest.mark.parametrize("checkpoint",[False,True])
def test_geo_decay_filter_update_reopen_and_arrow_ownership(tmp_path, checkpoint):
    db = Collection(tmp_path,1)
    db.apply_point_batch([PointMutation.upsert(i,vector=[i],fields=[
        field("meta",{"place":[{"lon":lon,"lat":0}]}),field("keep",i != 2)])
        for i,lon in ((1,0),(2,1),(3,2))])
    distance = geo(to="meta.place")
    raw = query(distance)
    assert [h.id for h in db.query(raw)] == [3,2,1]  # Formulas sort by descending score.
    nearest = query({"neg":distance})
    assert [h.id for h in db.query(nearest)] == [1,2,3]
    decay = query({"exp_decay":{"x":distance,"scale":100000}},score_threshold=0.5)
    assert [h.id for h in db.query(decay)] == [1]
    filtered = replace(raw,filter={"kind":"condition","name":"keep","operator":"eq","type":"bool","value":True})
    assert [h.id for h in db.query(filtered)] == [3,1]
    saved = query_record_batch(db,nearest)
    original = saved.to_pydict()
    db.set_payload({"lon":3},points=[1],key="meta.place[]")
    db.delete(2)
    expected = [(h.id,h.score) for h in db.query(nearest)]
    assert [i for i,_ in expected] == [3,1]
    if checkpoint:
        db.flush()
    db.close()
    assert saved.to_pydict() == original
    with closing(Collection(tmp_path,1)) as reopened:
        assert [(h.id,h.score) for h in reopened.query(nearest)] == expected
        nested = QueryRequest("formula",prefetch=(nearest,),formula=Formula({"neg":"$score"}))
        assert [h.id for h in reopened.query(nested)] == [1,3]
        reopened.set_payload({"lat":91},points=[1],key="meta.place[]")
        with pytest.raises(ValidationError,match="geo point"):
            reopened.query(replace(nearest,limit=1,score_threshold=1e30))


def test_geo_paths_defaults_empty_and_null(tmp_path):
    with closing(Collection(tmp_path,1)) as db:
        db.upsert(1,[1],[field("a.b",{"lon":0,"lat":0}),field("$score",{"lon":0,"lat":0})])
        assert db.query(query(geo(to='"a.b"')))[0].score == 0
        assert db.query(query(geo(to='"$score"')))[0].score == 0
        with pytest.raises(ValidationError,match="missing"):
            db.query(query(geo(to="a.b")))
        assert db.query(query(geo(to="a.b"),{'"a"."b"':[0,0]}))[0].score == 0
        db.set_payload({"a":{"b":[]}},points=[1])
        assert db.query(query(geo(to="a.b"),{"a.b":[0,0]}))[0].score == 0
        db.set_payload({"a":{"b":None}},points=[1])
        with pytest.raises(ValidationError,match="geo point"):
            db.query(query(geo(to="a.b"),{"a.b":[0,0]}))


@pytest.mark.parametrize("params",[
    None,[],{}, {"to":"location"},{"origin":{"lon":0,"lat":0}},
    {"origin":{"lon":0,"lat":0},"to":1},
    {"origin":{"lon":0,"lat":0},"to":"$score"},
    {"origin":{"lon":0,"lat":0},"to":"a[-1]"},
    {"origin":{"lon":0,"lat":0},"to":"location","unknown":1},
    {"origin":{"lon":float("inf"),"lat":0},"to":"location"},
    {"origin":{"lon":0,"lat":float("nan")},"to":"location"},
])
def test_geo_rejects_invalid_request_parameters(tmp_path,params):
    with closing(Collection(tmp_path,1)) as db:
        with pytest.raises(ValidationError):
            db.query(query({"geo_distance":params}))


def test_geo_query_keeps_cancellation_and_deadline_checks(tmp_path):
    with closing(Collection(tmp_path,1)) as db:
        db.upsert(1,[1],[field("location",{"lon":0,"lat":0})])
        token=CancellationToken()
        token.cancel()
        with pytest.raises(Exception,match="cancelled"):
            db.query(query(geo()),cancellation=token)
        with pytest.raises(Exception,match="deadline"):
            db.query(query(geo()),timeout_ns=1)
