"""Sparse recommendation paths against the pinned Rust scoring/search oracles."""
from contextlib import closing
import json
from pathlib import Path
import struct

import pytest

from akashadb import (CancellationToken, Collection, PayloadField, PointMutation,
                     ResourceLimits, SparseElement, ValidationError, VectorField)
from akashadb.arrow import recommend_field_record_batch

FIXTURES = Path(__file__).parents[1] / "fixtures/qdrant-recommendation"
SEARCH = json.loads((FIXTURES / "sparse-search.json").read_text())["cases"]
TRANSFORMS = json.loads((FIXTURES / "recommendation.json").read_text())["cases"]
PIPELINES = [(i, case) for i, case in enumerate(TRANSFORMS) if case["kind"] == "sparse"]
API_CASES = [case for case in SEARCH if not case["name"].startswith("pipeline_") and
             ((case["mode"] == "indexed" and case["allowed"] is None) or
              (case["mode"] == "plain" and case["size"] < 5000))]
PREDICATE = dict(kind="condition", name="keep", operator="eq", type="bool", value=True)


def vector(raw):
    return [SparseElement(term, value) for term, value in raw]


def f32(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


@pytest.mark.parametrize("case", API_CASES, ids=lambda c: c["name"] + "_" + c["mode"])
def test_sparse_average_index_paths_match_upstream(tmp_path, case):
    allowed = None if case["allowed"] is None else set(case["allowed"])
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(0, kind="sparse", metric="dot")})) as db:
        db.apply_point_batch([
            PointMutation.upsert(row, vectors={"v": vector(case["points"].get(str(row), []))},
                                 fields=[PayloadField("keep", "bool", allowed is None or row in allowed)])
            for row in range(case["size"])
        ])
        kwargs = dict(mode="approx", k=case["k"], filter=PREDICATE if case["mode"] == "plain" else None)
        hits = db.recommend_field("v", [vector(case["query"])], **kwargs)
        assert [hit.id for hit in hits] == [hit[0] for hit in case["expected"]]
        assert [hit.score for hit in hits] == [f32(hit[1]) for hit in case["expected"]]
        expected_path = "recommendation_sparse_empty" if not case["query"] else "recommendation_sparse_" + case["mode"]
        stats = db.last_search_stats()
        assert stats.planner_reason == expected_path
        assert stats.storage_name == "field-postings"
        assert stats.fallback_reason == ""
        assert db.recommend_field("v", [vector(case["query"])], **(kwargs | {"mode": "exact"})) == hits
        assert db.last_search_stats().planner_reason == expected_path


@pytest.mark.parametrize("source_index,sample", PIPELINES)
def test_sparse_composite_pipeline_matches_rust_sources(tmp_path, source_index, sample):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(0, kind="sparse", metric="dot"), "source": VectorField(0, kind="sparse", metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": vector(value)})
                              for i, value in enumerate(sample["candidates"])])
        positive = [vector(value) for value in sample["positive"]]
        negative = [vector(value) for value in sample["negative"]]
        for base, values, ids in ((10000, positive, sample["positive_ids"]), (20000, negative, sample["negative_ids"])):
            for i in ids:
                db.apply_point_batch([PointMutation.upsert(base+i, vectors={"source": values[i]})])
                values[i] = base+i
        kwargs = dict(strategy=sample["strategy"], lookup_field="source", mode="approx")
        if "error" in sample:
            with pytest.raises(ValidationError, match="positive|examples"):
                db.recommend_field("v", positive, negative, **kwargs)
            return
        expected = sample["expected"]
        path = "recommendation_sparse_scored"
        if sample["strategy"] == "average_vector":
            selected = "plain" if sample["positive_ids"] or sample["negative_ids"] else "indexed"
            searched = next(case for case in SEARCH if case["name"] == f"pipeline_{source_index}" and case["mode"] == selected)
            expected = [[row+1, bits] for row, bits in searched["expected"]]
            path = "recommendation_sparse_" + selected if searched["query"] else "recommendation_sparse_empty"
        hits = db.recommend_field("v", positive, negative, **kwargs)
        assert [hit.id for hit in hits] == [row[0] for row in expected]
        assert [hit.score for hit in hits] == pytest.approx([f32(row[1]) for row in expected], abs=2e-6, rel=2e-6)
        assert db.last_search_stats().planner_reason == path
        assert db.recommend_field("v", positive, negative, **(kwargs | {"mode": "exact"})) == hits
        assert db.last_search_stats().planner_reason == path
        batch = recommend_field_record_batch(db, "v", positive, negative, **kwargs)
    assert batch.to_pydict() == {"id": [hit.id for hit in hits], "score": [hit.score for hit in hits]}


@pytest.mark.parametrize("strategy", ["average_vector", "best_score", "sum_scores"])
def test_sparse_lookup_visibility_reopen_and_custom_zero_results(tmp_path, strategy):
    schema = {"v": VectorField(0, kind="sparse", metric="dot")}
    with closing(Collection(tmp_path, 1, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": vector([[1, i]])}) for i in range(1, 5)])
        db.flush()
        db.apply_point_batch([PointMutation.delete(2), PointMutation.update(3, vectors={"v": vector([[1, 8]])}),
                              PointMutation.upsert(5, vectors={"v": []}), PointMutation.upsert(6, vectors={"v": vector([[9, 1]])})])
        expected = db.recommend_field("v", [4], strategy=strategy, mode="approx")
        assert 4 not in [hit.id for hit in expected]
        assert 2 not in [hit.id for hit in expected]
        assert (5 in [hit.id for hit in expected]) == (strategy != "average_vector")
        assert (6 in [hit.id for hit in expected]) == (strategy != "average_vector")
    with closing(Collection(tmp_path, 1)) as db:
        assert db.recommend_field("v", [4], strategy=strategy, mode="approx") == expected


def test_sparse_controls_and_finite_scores(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(0, kind="sparse", metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": vector([[1, 3e38]])}, fields=[PayloadField("keep", "bool", False)]),
                              PointMutation.upsert(2, vectors={"v": vector([[1, 1]])}, fields=[PayloadField("keep", "bool", True)])])
        query = [vector([[1, 2]])]
        with pytest.raises(ValidationError, match="finite"):
            db.recommend_field("v", query, mode="approx")
        assert db.recommend_field("v", query, mode="approx", filter=PREDICATE)[0].id == 2
        with pytest.raises(ValidationError, match="ef_search"):
            db.recommend_field("v", query, mode="approx", ef_search=16)
        token = CancellationToken(); token.cancel()
        with pytest.raises(Exception, match="cancel"):
            db.recommend_field("v", [[]], mode="approx", cancellation=token)
        with pytest.raises(Exception, match="deadline"):
            db.recommend_field("v", query, mode="approx", timeout_ns=1)
    with closing(Collection(tmp_path, 1, limits=ResourceLimits(max_candidates=1))) as db:
        with pytest.raises(Exception, match="resource"):
            db.recommend_field("v", [vector([[1, 1]])], mode="approx")


@pytest.mark.parametrize("count", [4999, 5000])
def test_sparse_filtered_default_threshold_preserves_source_zero_policy(tmp_path, count):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(0, kind="sparse", metric="dot")})) as db:
        db.apply_point_batch([
            PointMutation.upsert(row, vectors={"v": vector([[1, 1], [2, -1]]) if row == 0 else []},
                                 fields=[PayloadField("keep", "bool", True)])
            for row in range(count)
        ])
        hits = db.recommend_field("v", [vector([[1, 1], [2, 1]])], mode="approx", filter=PREDICATE)
        assert [(hit.id, hit.score) for hit in hits] == ([(0, 0.0)] if count == 4999 else [])
        assert db.last_search_stats().planner_reason == (
            "recommendation_sparse_plain" if count == 4999 else "recommendation_sparse_indexed")


@pytest.mark.parametrize("strategy", ["average_vector", "best_score", "sum_scores"])
def test_sparse_external_lookup_keeps_colliding_target_id(tmp_path, strategy):
    schema = {"v": VectorField(0, kind="sparse", metric="dot")}
    with closing(Collection(tmp_path / "source", 1, vectors=schema)) as source:
        source.apply_point_batch([PointMutation.upsert(1, vectors={"v": vector([[1, 2]])})])
        with closing(Collection(tmp_path / "target", 1, vectors=schema)) as target:
            target.apply_point_batch([PointMutation.upsert(1, vectors={"v": vector([[1, 3]])}),
                                      PointMutation.upsert(2, vectors={"v": vector([[1, 1]])})])
            expected = target.recommend_field("v", [vector([[1, 2]])], strategy=strategy, mode="approx")
            actual = target.recommend_field("v", [1], lookup_from=source, strategy=strategy, mode="approx")
            assert actual == expected
            assert actual[0].id == 1
