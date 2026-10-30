"""Original-source datetime behavior through actual native Python/Arrow queries."""
from contextlib import closing
from dataclasses import replace
import json
from pathlib import Path
import struct

import pytest

from akashadb import CancellationToken, Collection, Formula, PointMutation, QueryRequest, ValidationError
from akashadb.arrow import query_record_batch
from test_formula_payload import field


FIXTURE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-datetime/datetime.json").read_text())


def query(expression, defaults=None, **options):
    return QueryRequest("formula", prefetch=(QueryRequest(),),
                        formula=Formula(expression, defaults or {}), **options)


def test_public_datetime_formulas_match_original_qdrant_and_chrono(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        for i, case in enumerate(FIXTURE["formulas"]):
            db.apply_point_batch([PointMutation.upsert(1, fields=[field(k, v) for k, v in case["payload"].items()])])
            request = query(case["expression"], case["defaults"])
            if case["expected_bits"] is None:
                with pytest.raises(ValidationError):
                    db.query(request)
                with pytest.raises(ValidationError):
                    query_record_batch(db, request)
            else:
                hits = db.query(request)
                assert [hit.id for hit in hits] == [1], i
                assert struct.unpack("<I", struct.pack("<f", hits[0].score))[0] == case["expected_bits"], i
                assert query_record_batch(db, request).to_pydict() == {"id": [1], "score": [hits[0].score]}, i


@pytest.mark.parametrize("value", [None, False, 0, [], {}, "", "2023-02-29", "2024-01-01T24:00:00Z",
    "2024-01-01T01:02:61Z", "2024-01-01T01:02:03+24:00", "2024-01-01T01:02:03.",
    "+262143-01-01", "-262144-01-01", "2024-01-01junk", "0" * 65_537])
def test_invalid_datetime_constant_fails_before_candidates_and_short_circuit(tmp_path, value):
    with closing(Collection(tmp_path, 1)) as db:
        with pytest.raises(ValidationError):
            db.query(query({"mult": [0, {"datetime": value}]}))


@pytest.mark.parametrize("value", ["2024-02-29", "2024-02-29T01:02", "2024-02-29 01:02:03",
    "2024-02-29T01:02:03+08", "2024-02-29t1:2:3 utc", "+10000-01-01T00:00:00Z",
    "1969-12-31T23:59:60.123456789123Z"])
def test_valid_datetime_constants_allow_empty_queries(tmp_path, value):
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query(query({"datetime": value})) == []


@pytest.mark.parametrize("checkpoint", [False, True])
def test_datetime_decay_updates_reopen_filter_and_arrow_ownership(tmp_path, checkpoint):
    db = Collection(tmp_path, 1)
    db.apply_point_batch([PointMutation.upsert(i, vector=[i], fields=[
        field("meta", {"created": [f"2025-03-{day}"]}), field("keep", i != 2)])
        for i, day in [(1, 18), (2, 19), (3, 20)]])
    raw = query({"datetime_key": "meta.created"})
    assert [h.id for h in db.query(raw)] == [3, 2, 1]
    decay = query({"exp_decay": {"x": {"datetime_key": "meta.created"},
                   "target": {"datetime": "2025-03-19"}, "scale": 86400}})
    assert [h.id for h in db.query(decay)] == [2, 1, 3]
    assert [h.id for h in db.query(replace(decay, score_threshold=0.75))] == [2]
    filtered = replace(raw, filter={"kind": "condition", "name": "keep", "operator": "eq", "type": "bool", "value": True})
    assert [h.id for h in db.query(filtered)] == [3, 1]
    saved = query_record_batch(db, decay)
    original = saved.to_pydict()
    db.set_payload({"created": "2025-03-21"}, points=[1], key="meta")
    db.delete(2)
    expected = [(h.id, h.score) for h in db.query(decay)]
    assert [i for i, _ in expected] == [3, 1]
    if checkpoint:
        db.flush()
    db.close()
    assert saved.to_pydict() == original
    with closing(Collection(tmp_path, 1)) as reopened:
        assert [(h.id, h.score) for h in reopened.query(decay)] == expected
        nested = QueryRequest("formula", prefetch=(raw,), formula=Formula({"neg": "$score"}))
        assert [h.id for h in reopened.query(nested)] == [3, 1]
        reopened.set_payload({"created": "invalid"}, points=[1], key="meta")
        with pytest.raises(ValidationError, match="datetime"):
            reopened.query(replace(decay, limit=1, score_threshold=10))


def test_datetime_payload_paths_defaults_and_lazy_errors(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1], [field("a.b", "1970-01-01"), field("$score", "1970-01-01")])
        for path in ['"a.b"', '"$score"']:
            assert db.query(query({"datetime_key": path}))[0].score == 0
        expr = {"datetime_key": "a.b"}
        with pytest.raises(ValidationError, match="missing"):
            db.query(query(expr))
        assert db.query(query(expr, {'"a"."b"': "1970-01-01"}))[0].score == 0
        db.set_payload({"a": {"b": []}}, points=[1])
        assert db.query(query(expr, {"a.b": "1970-01-01"}))[0].score == 0
        db.set_payload({"a": {"b": None}}, points=[1])
        with pytest.raises(ValidationError, match="datetime"):
            db.query(query(expr, {"a.b": "1970-01-01"}))
        assert db.query(query({"mult": [0, expr]}))[0].score == 0


@pytest.mark.parametrize("path", [None, False, 0, [], {}, "$score", "x[-1]", ""])
def test_datetime_key_rejects_invalid_paths(tmp_path, path):
    with closing(Collection(tmp_path, 1)) as db:
        with pytest.raises(ValidationError):
            db.query(query({"datetime_key": path}))


def test_datetime_keeps_query_controls(tmp_path):
    with closing(Collection(tmp_path, 1)) as db:
        db.upsert(1, [1])
        token = CancellationToken()
        token.cancel()
        with pytest.raises(Exception, match="cancelled"):
            db.query(query({"datetime": "2025-03-18"}), cancellation=token)
        with pytest.raises(Exception, match="deadline"):
            db.query(query({"datetime": "2025-03-18"}), timeout_ns=1)
