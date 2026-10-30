"""Source formula fixtures and public query-tree/Arrow integration."""
from contextlib import closing
from dataclasses import replace
import json
from pathlib import Path
import struct

import pytest

from akashadb import (CancellationToken, Collection, Formula, PayloadField,
                     PointMutation, QueryRequest, ResourceLimits, ValidationError,
                     VectorField)
from akashadb.arrow import query_record_batch


CASES = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-formula/formula.json").read_text())["cases"]


def predicate(name, value, kind="int"):
    return dict(kind="condition", name=name, operator="eq", type=kind, value=value)


def native_conditions(value):
    if isinstance(value, dict):
        if set(value) == {"condition"}:
            return {"condition": {"kind": "all" if value["condition"] else "any", "children": []}}
        return {k: native_conditions(v) for k, v in value.items()}
    if isinstance(value, list):
        return [native_conditions(v) for v in value]
    return value


def field(name, value):
    return PayloadField(name, {str: "string", bool: "bool", int: "int", float: "float"}[type(value)], value)


def request(expression, defaults=None, **options):
    return QueryRequest("formula", formula=Formula(expression, defaults or {}), **options)


@pytest.mark.parametrize("case", CASES, ids=lambda c: str(CASES.index(c)))
def test_public_formula_matches_qdrant(case, tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1, metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [2.25]},
            fields=[field(k, v) for k, v in case["payload"].items()])])
        source = QueryRequest("nearest", "v", target=[1], limit=1)
        empty = replace(source, filter=predicate("absent", 0))
        query = request(native_conditions(case["expression"]), case["defaults"], prefetch=(source, empty))
        if case["expected_bits"] is None:
            with pytest.raises(ValidationError):
                db.query(query)
        else:
            hits = db.query(query)
            assert [h.id for h in hits] == [1]
            assert struct.unpack("<I", struct.pack("<f", hits[0].score))[0] == case["expected_bits"]


@pytest.fixture
def db(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(2, metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": v}, fields=[
            field("weight", i), field("keep", i >= 3)]) for i, v in enumerate(
                [[5, 0], [4, 1], [0, 5], [1, 4], [3, 3]], 1)])
        yield db


def sources():
    return tuple(QueryRequest("nearest", "v", target=v, limit=2) for v in ([1, 0], [0, 1]))


def test_formula_union_scores_defaults_condition_offset_and_arrow(db):
    query = request({"sum": ["$score", "$score[1]", "weight",
                             {"mult": [10, {"condition": predicate("keep", True, "bool")}]}]},
                    {"$score[1]": 0.5}, prefetch=sources())
    hits = db.query(query)
    assert [(h.id, h.score) for h in hits] == [(3, 18), (4, 18), (1, 6.5), (2, 6.5)]
    assert db.query(replace(query, offset=1, limit=2)) == hits[1:3]
    assert db.query(replace(query, score_threshold=18)) == hits[:2]
    batch = query_record_batch(db, query)
    db.close()
    assert batch.to_pydict() == {"id": [h.id for h in hits], "score": [h.score for h in hits]}


def test_nested_formula_filters_before_prefetch_topk_and_duplicate_union(db):
    child = request({"sum": ["$score", "weight"]}, prefetch=sources(), limit=2)
    parent = request({"neg": "$score"}, prefetch=(child,), limit=1)
    assert [(h.id, h.score) for h in db.query(parent)] == [(1, -6)]
    filtered = request("weight", prefetch=(sources()[0],), filter=predicate("keep", True, "bool"))
    assert [h.id for h in db.query(filtered)] == [5, 4]
    repeated = request({"sum": ["$score", "$score[1]"]}, prefetch=(sources()[0], sources()[0]))
    assert [(h.id, h.score) for h in db.query(repeated)] == [(1, 10), (2, 8)]


def test_formula_all_candidates_must_evaluate_even_below_topk_or_threshold(db):
    db.apply_point_batch([PointMutation.update(2, fields=[field("weight", "wrong")])])
    query = request("weight", prefetch=(QueryRequest(limit=2),), limit=1, score_threshold=1000)
    with pytest.raises(ValidationError, match="number"):
        db.query(query)
    # Defaults replace absent values, not values with the wrong stored type.
    with pytest.raises(ValidationError, match="number"):
        db.query(replace(query, formula=Formula("weight", {"weight": 0})))
    empty = request("missing", prefetch=(QueryRequest(filter=predicate("absent", 1)),))
    assert db.query(empty) == []


def test_formula_shared_budget_bounds_and_cancellation(db):
    query = request("$score", prefetch=sources())
    db.limits = ResourceLimits(max_candidates=13)
    with pytest.raises(ValidationError, match="resource limit"):
        db.query(query)
    db.limits = ResourceLimits(max_candidates=14)
    assert len(db.query(query)) == 4
    db.limits = ResourceLimits(max_query_batch=3)
    with pytest.raises(ValidationError, match="resource limit"):
        db.query(query)
    db.limits = ResourceLimits(max_query_batch=4)
    assert len(db.query(query)) == 4
    token = CancellationToken()
    token.cancel()
    with pytest.raises(Exception, match="cancelled"):
        db.query(query, cancellation=token)
    with pytest.raises(Exception, match="deadline"):
        db.query(query, timeout_ns=1)


@pytest.mark.parametrize("expression", [
    True, None, [], {}, {"sum": [1], "mult": [2]}, {"sum": 1}, {"unknown": 1},
    {"div": {"left": 1}}, {"div": {"left": 1, "right": 0, "by_zero_default": float("inf")}},
    {"pow": {"base": 2, "exponent": 3, "extra": 4}},
    {"gauss_decay": {"x": 1, "scale": 0}}, {"exp_decay": {"x": 1, "midpoint": 1}},
    {"lin_decay": {"x": 1, "midpoint": -0.1}}, {"exp_decay": {"x": 1, "scale": True}},
    float("nan"), 1e100, "$unknown", "$score[]", "$score[-1]", "$score[1][2]",
    {"geo_distance": {"to": "position"}},
])
def test_formula_rejects_invalid_or_unimplemented_expressions(db, expression):
    with pytest.raises(ValidationError):
        db.query(request(expression, prefetch=sources()))


@pytest.mark.parametrize("defaults", [{"x": float("inf")},
                                     {"$score": 1, "$score[0]": 2}])
def test_formula_rejects_invalid_defaults(db, defaults):
    with pytest.raises(ValidationError):
        db.query(request(1, defaults, prefetch=sources()))


def test_formula_query_requires_sources_and_rejects_conflicting_options(db):
    for query in (request(1), QueryRequest("formula", prefetch=sources()),
                  replace(sources()[0], formula=Formula(1)),
                  request(1, prefetch=sources(), using="v"),
                  request(1, prefetch=sources(), mode="approx")):
        with pytest.raises(ValidationError):
            db.query(query)


def test_formula_cycles_depth_and_condition_cycles_are_bounded(db):
    cycle = {"neg": None}
    cycle["neg"] = cycle
    with pytest.raises(ValidationError, match="resource limit"):
        db.query(request(cycle, prefetch=sources()))
    expr = 1
    for _ in range(64):
        expr = {"neg": expr}
    assert all(h.score == 1 for h in db.query(request(expr, prefetch=sources())))
    with pytest.raises(ValidationError, match="resource limit"):
        db.query(request({"neg": expr}, prefetch=sources()))
    condition = {"kind": "not"}
    condition["child"] = condition
    with pytest.raises(ValidationError, match="resource limit"):
        db.query(request({"condition": condition}, prefetch=sources()))


def test_formula_reopen_uses_updated_payload_and_live_heads(db, tmp_path):
    query = request("weight", prefetch=(QueryRequest(),))
    db.flush()
    db.apply_point_batch([PointMutation.update(1, fields=[field("weight", 100)]), PointMutation.delete(5)])
    assert [h.id for h in db.query(query)] == [1, 4, 3, 2]
    db.close()
    with closing(Collection(tmp_path, 1)) as reopened:
        assert [h.id for h in reopened.query(query)] == [1, 4, 3, 2]


@pytest.mark.parametrize("close_source", [False, True])
def test_formula_condition_conversion_rechecks_owner_lifetimes(db, tmp_path, close_source):
    with closing(Collection(tmp_path / "lookup", 1, vectors={"v": VectorField(2, metric="dot")})) as source:
        source.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1, 0]})])
        class ClosingFloat:
            def __float__(self):
                (source if close_source else db).close()
                return 1.0
        query = request({"condition": predicate("weight", ClosingFloat(), "float")},
                        prefetch=(QueryRequest("nearest", "v", target=1, lookup_from=source),))
        with pytest.raises(Exception, match="closed"):
            db.query(query)
