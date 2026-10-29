"""Public nearest entry points against actual upstream sparse-search fixtures."""
from contextlib import closing
import json
from pathlib import Path
import struct

import pytest

from akashadb import (CancellationToken, Collection, FieldQuery, PayloadField,
                     PointMutation, ResourceLimits, SearchRequest, SparseElement,
                     ValidationError, VectorField)
from akashadb.arrow import search_field_record_batch, search_fields_record_batch, search_record_batch

CASES = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-sparse-nearest/search.json").read_text())["cases"]
API_CASES = [c for c in CASES if not c["name"].startswith("pipeline_") and
             ((c["mode"] == "indexed" and c["allowed"] is None) or
              (c["mode"] == "plain" and c["size"] < 5000))]
KEEP = dict(kind="condition", name="keep", operator="eq", type="bool", value=True)
SCHEMA = {"s": VectorField(0, kind="sparse", metric="dot"), "dense": VectorField(1, metric="dot")}


def sparse(raw):
    return [SparseElement(term, value) for term, value in raw]


def bits(value):
    return struct.unpack("<I", struct.pack("<f", value))[0]


def assert_source(hits, case):
    assert [[hit.id, bits(hit.score)] for hit in hits] == case["expected"]


@pytest.mark.parametrize("case", API_CASES, ids=lambda c: c["name"] + "_" + c["mode"])
def test_default_named_exact_approx_and_arrow_match_source(tmp_path, case):
    admitted = None if case["allowed"] is None else set(case["allowed"])
    with closing(Collection(tmp_path, 1, vectors=SCHEMA)) as db:
        db.apply_point_batch([
            PointMutation.upsert(row, vector=[1], sparse=sparse(case["points"].get(str(row), [])),
                                 vectors={"s": sparse(case["points"].get(str(row), []))},
                                 fields=[PayloadField("keep", "bool", admitted is None or row in admitted)])
            for row in range(case["size"])
        ])
        query = sparse(case["query"])
        predicate = KEEP if case["mode"] == "plain" else None
        for mode in ("exact", "approx"):
            hits = db.search_field("s", query, case["k"], mode=mode, filter=predicate)
            assert_source(hits, case)
            assert db.last_search_stats().planner_reason == (
                "field_sparse_empty" if not query else "field_sparse_" + case["mode"])
        request = SearchRequest(metric="dot", mode="sparse", sparse=query, k=case["k"], filter=predicate)
        assert_source(db.search(request), case)
        field_batch = search_field_record_batch(db, "s", query, case["k"], filter=predicate, mode="approx")
        default_batch = search_record_batch(db, request)
    for batch in (field_batch, default_batch):
        rows = batch.to_pydict()
        assert [[id, bits(score)] for id, score in zip(rows["id"], rows["score"])] == case["expected"]


@pytest.mark.parametrize("name", ["zero_cancellation_and_no_overlap", "rounded_products_cancel", "overflow_admission", "filtered_zero", "minimum_threshold"])
def test_sparse_reranking_is_a_candidate_id_filtered_search(tmp_path, name):
    case = next(c for c in CASES if c["name"] == name and c["mode"] == "plain")
    admitted = None if case["allowed"] is None else set(case["allowed"])
    with closing(Collection(tmp_path, 1, vectors=SCHEMA)) as db:
        db.apply_point_batch([
            PointMutation.upsert(row, vectors={"s": sparse(case["points"].get(str(row), [])), "dense": [1]},
                                 fields=[PayloadField("keep", "bool", admitted is None or row in admitted)])
            for row in range(case["size"])
        ])
        # This high-scoring sparse point is absent from the candidate field.
        db.apply_point_batch([PointMutation.upsert(999, vectors={"s": sparse([[1, 100]])})])
        branches = [FieldQuery("dense", [1])]
        rerank = FieldQuery("s", sparse(case["query"]))
        kwargs = dict(fetch_k=case["size"], filter=KEEP, rerank=rerank)
        assert_source(db.search_fields(branches, case["k"], **kwargs), case)
        batch = search_fields_record_batch(db, branches, case["k"], **kwargs)
    assert batch.to_pydict()["id"] == [row[0] for row in case["expected"]]


@pytest.mark.parametrize("count", [4999, 5000])
def test_default_named_and_lookup_share_filtered_threshold(tmp_path, count):
    query = sparse([[1, 1], [2, 1]])
    cancel = sparse([[1, 1], [2, -1]])
    with closing(Collection(tmp_path, 1, vectors=SCHEMA)) as db:
        db.apply_point_batch([PointMutation.upsert(row, sparse=cancel if row == 0 else [],
                                vectors={"s": cancel if row == 0 else []},
                                fields=[PayloadField("keep", "bool", True)]) for row in range(count)])
        expected = [(0, 0.0)] if count == 4999 else []
        for mode in ("exact", "approx"):
            assert [(h.id, h.score) for h in db.search_field("s", query, 10, filter=KEEP, mode=mode)] == expected
        assert [(h.id, h.score) for h in db.search(SearchRequest(metric="dot", mode="sparse", sparse=query, k=10, filter=KEEP))] == expected
        db.apply_point_batch([PointMutation.upsert(-1, vectors={"s": query})])
        # The source ID is excluded before computing eligible cardinality.
        for mode in ("exact", "approx"):
            assert [(h.id, h.score) for h in db.search_field_by_id("s", -1, 10, mode=mode)] == expected


def test_sparse_default_and_hybrid_visibility_reopen(tmp_path):
    query = sparse([[1, 1], [2, 1]])
    with closing(Collection(tmp_path, 1, vectors=SCHEMA)) as db:
        db.apply_point_batch([PointMutation.upsert(1, vector=[2], sparse=sparse([[1, 1], [2, -1]]), vectors={"s": sparse([[1, 1], [2, -1]])}, fields=[PayloadField("keep", "bool", True)]),
                              PointMutation.upsert(2, vector=[1], sparse=sparse([[1, -1]]), vectors={"s": sparse([[1, -1]])}, fields=[PayloadField("keep", "bool", True)])])
        db.flush()
        db.apply_point_batch([PointMutation.delete(2), PointMutation.upsert(3, vector=[3], sparse=sparse([[1, -2]]), vectors={"s": sparse([[1, -2]])}, fields=[PayloadField("keep", "bool", True)])])
        request = SearchRequest(metric="dot", mode="sparse", sparse=query, k=10, filter=KEEP)
        expected = db.search(request)
        assert [(h.id, h.score) for h in expected] == [(1, 0), (3, -2)]
        hybrid = SearchRequest(mode="hybrid", metric="dot", vector=[1], sparse=query, k=2, fetch_k=2, filter=KEEP)
        # Both rankings contain 1 and 3; each gets one first and one second rank.
        fused = db.search(hybrid)
        assert [h.id for h in fused] == [1, 3]
        assert fused[0].score == fused[1].score
    with closing(Collection(tmp_path, 1)) as db:
        assert db.search(request) == expected
        assert db.search(hybrid) == fused
        assert db.search_field("s", query, 10, filter=KEEP) == expected


def test_sparse_controls_modes_and_recommendation_finite_contract(tmp_path):
    with closing(Collection(tmp_path, 1, vectors=SCHEMA)) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"s": sparse([[1, 3e38]])}), PointMutation.upsert(2)])
        query = sparse([[1, 2]])
        assert db.search_field("s", query, 1, mode="approx")[0].score == float("inf")
        with pytest.raises(ValidationError, match="finite"):
            db.recommend_field("s", [query], mode="approx")
        for options in (dict(ef_search=16), dict(rerank_k=1)):
            with pytest.raises(ValidationError, match="HNSW"):
                db.search_field("s", query, 1, mode="approx", **options)
        token = CancellationToken(); token.cancel()
        with pytest.raises(Exception, match="cancel"):
            db.search_field("s", [], 1, mode="approx", cancellation=token)
        with pytest.raises(Exception, match="deadline"):
            db.search_field("s", query, 1, mode="approx", timeout_ns=1)
        assert db.search_fields([FieldQuery("s", sparse([[1, 1]]), mode="approx")], 1, fetch_k=1)[0].id == 1
    with closing(Collection(tmp_path, 1, limits=ResourceLimits(max_candidates=1))) as db:
        with pytest.raises(Exception, match="resource"):
            db.search_field("s", query, 1, mode="approx")
