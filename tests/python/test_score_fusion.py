"""Public DBSF paths checked against native upstream normalization fixtures."""

from contextlib import closing
import json
from pathlib import Path

import numpy as np
import pytest

from akashadb import (CancellationToken, Collection, FieldQuery, PayloadField,
                     PointMutation, ResourceLimits, ValidationError, VectorField)
from akashadb.arrow import search_fields_record_batch


FIXTURE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-dbsf/normalization.json").read_text())


@pytest.mark.parametrize("sample", [sample for sample in FIXTURE["cases"]
                                   if sample["input"] == sorted(sample["input"], reverse=True)])
def test_native_field_scores_match_rust_fixtures(tmp_path, sample):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1, metric="dot")})) as db:
        if sample["input"]:
            db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [score]})
                                  for i, score in enumerate(sample["input"])])
        hits = db.search_fields([FieldQuery("v", [1.0])], 200, fetch_k=200, fusion="dbsf")
        actual = {hit.id: hit.score for hit in hits}
        assert set(actual) == set(range(len(sample["input"])))
        np.testing.assert_allclose([actual[i] for i in range(len(actual))], sample["output"], atol=1e-5, rtol=0)
        assert db.last_search_stats().metric_name == "dbsf"


def test_overlap_filter_rerank_arrow_and_reopen(tmp_path):
    fields = {"a": VectorField(1, metric="dot"), "b": VectorField(1, metric="dot"),
              "final": VectorField(1, metric="l2")}
    queries = [FieldQuery("a", [1.0]), FieldQuery("b", [1.0])]
    predicate = {"kind": "condition", "name": "keep", "operator": "eq", "type": "bool", "value": True}

    def verify(db):
        # Each branch is constant: upstream normalizes each candidate to 0.5.
        hits = db.search_fields(queries, 4, fetch_k=4, fusion="dbsf", filter=predicate)
        assert [(hit.id, hit.score) for hit in hits] == [(2, 1.0), (1, 0.5), (3, 0.5)]
        assert db.last_search_stats().metric_name == "dbsf"
        arrow = search_fields_record_batch(db, queries, 4, fetch_k=4, fusion="dbsf", filter=predicate)
        assert arrow.to_pydict() == {"id": [2, 1, 3], "score": [1.0, 0.5, 0.5]}
        reranked = db.search_fields(queries, 2, fetch_k=4, fusion="dbsf", filter=predicate,
                                   rerank=FieldQuery("final", [0.0]))
        assert [(hit.id, hit.score) for hit in reranked] == [(3, 1.0), (1, 4.0)]
        assert db.last_search_stats().storage_name == "field-rerank"
        assert db.search_fields(queries, 3, fetch_k=4) == db.search_fields(queries, 3, fetch_k=4, fusion="rrf")
        return arrow

    with closing(Collection(tmp_path, 1, vectors=fields)) as db:
        db.apply_point_batch([
            PointMutation.upsert(1, vectors={"a": [7.0], "final": [2.0]}, fields=[PayloadField("keep", "bool", True)]),
            PointMutation.upsert(2, vectors={"a": [7.0], "b": [-5.0], "final": [3.0]}, fields=[PayloadField("keep", "bool", True)]),
            PointMutation.upsert(3, vectors={"b": [-5.0], "final": [1.0]}, fields=[PayloadField("keep", "bool", True)]),
            PointMutation.upsert(4, vectors={"a": [999.0], "b": [999.0]}, fields=[PayloadField("keep", "bool", False)]),
        ])
        arrow = verify(db)
        db.flush()
    assert arrow["score"].to_pylist() == [1.0, 0.5, 0.5]
    with closing(Collection(tmp_path, 1)) as db:
        verify(db)


def test_invalid_mode_empty_and_cancellation(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1)})) as db:
        query = [FieldQuery("v", [0.0])]
        assert db.search_fields(query, 1, fusion="dbsf") == []
        for invalid in ("", "weighted", None, 1, []):
            with pytest.raises(ValidationError, match="fusion"):
                db.search_fields(query, 1, fusion=invalid)
        token = CancellationToken()
        token.cancel()
        with pytest.raises(Exception, match="cancel"):
            db.search_fields(query, 1, fusion="dbsf", cancellation=token)


def test_branch_candidate_budget_is_still_enforced(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1)}, limits=ResourceLimits(max_candidates=1))) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1.0]})])
        with pytest.raises(Exception, match="candidate resource limit"):
            db.search_fields([FieldQuery("v", [1.0])] * 2, 1, fusion="dbsf")


def test_native_score_must_fit_f32_at_dbsf_boundary(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1, metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [3e38]})])
        # Native named-field scoring remains F64, but DBSF has an F32 contract.
        assert db.search_field("v", [3.0], 1)[0].score > 3e38
        with pytest.raises(ValidationError, match="finite Float32"):
            db.search_fields([FieldQuery("v", [3.0])], 1, fusion="dbsf")
