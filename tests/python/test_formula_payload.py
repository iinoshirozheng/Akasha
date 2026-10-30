"""Actual Qdrant payload retriever and numeric scorer at the public boundary."""
from contextlib import closing
from dataclasses import replace
import json
from pathlib import Path
import struct

import pytest

from akashadb import Collection, Formula, PayloadField, PointMutation, QueryRequest, ValidationError
from akashadb.arrow import query_record_batch


CASES = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-formula-payload/formula.json").read_text())["cases"]


def field(name, value):
    kind = {str: "string", bool: "bool", int: "int", float: "float", list: "array",
            dict: "object", type(None): "null"}[type(value)]
    if type(value) is int and value > 2**63-1:
        kind = "uint"
    return PayloadField(name, kind, value)


def request(expression, defaults=None):
    return QueryRequest("formula", prefetch=(QueryRequest(),), formula=Formula(expression, defaults or {}))


def test_public_and_arrow_match_original_rich_formula_cases(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        for i, case in enumerate(CASES):
            db.apply_point_batch([PointMutation.upsert(1,
                fields=[field(k, v) for k, v in case["payload"].items()])])
            query = request(case["expression"], case["defaults"])
            if case["expected_bits"] is None:
                with pytest.raises(ValidationError):
                    db.query(query)
                with pytest.raises(ValidationError):
                    query_record_batch(db, query)
            else:
                hits = db.query(query)
                assert [hit.id for hit in hits] == [1], i
                assert struct.unpack("<I", struct.pack("<f", hits[0].score))[0] == case["expected_bits"], i
                assert query_record_batch(db, query).to_pydict() == {"id": [1], "score": [hits[0].score]}, i


@pytest.mark.parametrize("checkpoint", [False, True])
def test_rich_formula_payload_update_reopen_nested_tree_and_arrow_lifetime(tmp_path, checkpoint):
    db = Collection(tmp_path, 1)
    db.apply_point_batch([PointMutation.upsert(i, fields=[field("meta", [{"weight": [i]}])]) for i in (1,2,3)])
    first = request("meta[].weight")
    assert [(x.id,x.score) for x in db.query(first)] == [(3,3),(2,2),(1,1)]
    retained = query_record_batch(db, first)
    db.set_payload({"weight": [9]}, points=[1], key="meta[]")
    db.delete_payload(["meta[].weight"], points=[2])
    first = replace(first, formula=Formula("meta[].weight", {'"meta"[].weight': 4}))
    parent = QueryRequest("formula", prefetch=(first,), formula=Formula({"neg": "$score"}))
    expected = [(3,-3),(2,-4),(1,-9)]
    assert [(x.id,x.score) for x in db.query(parent)] == expected
    if checkpoint:
        db.flush()
    db.close()
    assert retained.to_pydict() == {"id":[3,2,1],"score":[3,2,1]}
    with closing(Collection(tmp_path, 1)) as reopened:
        assert [(x.id,x.score) for x in reopened.query(parent)] == expected
        reopened.set_payload({"weight": None}, points=[1], key="meta[]")
        assert [(x.id,x.score) for x in reopened.query(first)] == [(1,4),(2,4),(3,3)]


@pytest.mark.parametrize("default", [None, [], {}, [3], {"nested":[None,2**64-1]}, True])
def test_rich_defaults_are_accepted_without_flattening_or_numeric_coercion(tmp_path, default):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1])
        assert db.query(request(1, {"unused":default}))[0].score == 1
        assert db.query(request("$score[1]", {"$score[1]":default}))[0].score == 0
        with pytest.raises(ValidationError, match="number"):
            db.query(request("missing", {"missing":default}))


@pytest.mark.parametrize("kind", ["depth", "cycle", "nodes", "bytes", "integer", "key", "nonfinite"])
def test_rich_default_validation_is_bounded_before_evaluation(tmp_path, kind):
    defaults = {}
    if kind in ("depth", "cycle"):
        value = []
        if kind == "cycle":
            value.append(value)
        else:
            for _ in range(64):
                value = [value]
        defaults["unused"] = value
    elif kind == "nodes":
        defaults = {"a":[None]*32767, "b":[None]*32767, "c":None}
    elif kind == "bytes":
        defaults = {"a":"x"*(8*1024*1024), "b":"y"*(8*1024*1024)}
    elif kind == "integer":
        defaults = {"unused":{"nested":2**64}}
    elif kind == "key":
        defaults = {"unused":{1:"bad key"}}
    else:
        defaults = {"unused":[float("nan")]}
    with closing(Collection(tmp_path, 1)) as db:
        # Empty candidates and short circuit do not bypass request conversion.
        with pytest.raises(ValidationError):
            db.query(request({"mult":[0,"missing"]}, defaults))
        db.upsert(1,[1])
        assert db.query(request(1))[0].score == 1


def test_maximum_depth_and_uint64_defaults_are_numeric(tmp_path):
    value = 2**64-1
    for _ in range(64):
        value = [value]
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1], [field("a",value)])
        score = float(2**64)  # UInt64 MAX rounds through F64 to F32.
        assert db.query(request("a"+"[0]"*64))[0].score == score
        assert db.query(request("missing", {"missing":2**64-1, "unused":value}))[0].score == score


def test_default_mapping_conversion_rechecks_collection_owner(tmp_path):
    db = Collection(tmp_path,1)
    db.upsert(1,[1])
    class ClosingDefaults:
        def keys(self):
            db.close()
            return ["a"]
        def __getitem__(self,key):
            return {"nested":[1]}
    with pytest.raises(Exception,match="closed"):
        db.query(request(1,ClosingDefaults()))
