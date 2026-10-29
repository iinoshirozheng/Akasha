"""Composite recommendation scores must drive HNSW traversal itself."""
from contextlib import closing
import json
from pathlib import Path
import struct

import pytest

from akashadb import (CancellationToken, Collection, CollectionConfig, PayloadField,
                     PointMutation, ResourceLimits, ValidationError, VectorField)
from akashadb.arrow import recommend_field_record_batch

REFERENCE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-recommendation/recommendation.json").read_text())
DENSE_CASES = [sample for sample in REFERENCE["cases"] if sample["kind"] == "dense" and "expected" in sample]


def f32(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def field(metric="dot", dtype="f32", dimension=3, *, complete_graph=False):
    kwargs = dict(m=128, m0=128, ef_construction=128) if complete_graph else {}
    config = CollectionConfig(dimension=dimension, ann_metric=metric, **kwargs)
    return VectorField(dimension, dtype=dtype, metric=metric, hnsw=config)


@pytest.mark.parametrize("sample", DENSE_CASES)
def test_hnsw_recommendations_match_upstream_scores_at_full_breadth(tmp_path, sample):
    # Replicate source candidates to exceed the exact planner threshold. This
    # tests real graph traversal, not a small-collection exact fallback. Expected
    # scores come from unedited upstream transforms/metrics, not Akasha exact.
    # Degree/beam exceed the 112 rows so all source candidates are reachable;
    # this is a scoring integration oracle, not an ANN recall acceptance run.
    vectors = sample["candidates"] * 16
    schema = {"v": field(sample["metric"], complete_graph=True), "source": VectorField(3, metric=sample["source_metric"])}
    with closing(Collection(tmp_path, 1, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": value}) for i, value in enumerate(vectors)])
        positive = list(sample["positive"])
        negative = list(sample["negative"])
        for base, values, indices in ((10000, positive, sample["positive_ids"]), (20000, negative, sample["negative_ids"])):
            for index in indices:
                db.apply_point_batch([PointMutation.upsert(base+index, vectors={"source": values[index]})])
                values[index] = base+index
        scores = {id: f32(bits) for id, bits in sample["expected"]}
        expected = [(i+1, scores[i % 7 + 1]) for i in range(len(vectors))]
        smaller = sample["metric"] == "l2" and sample["strategy"] == "average_vector"
        expected.sort(key=lambda hit: (hit[1] if smaller else -hit[1], hit[0]))
        hits = db.recommend_field("v", positive, negative, 10, strategy=sample["strategy"],
                                  lookup_field="source", mode="approx", ef_search=128)
        stats = db.last_search_stats()
        assert stats.planner_reason == "recommendation_hnsw"
        assert stats.fallback_reason == ""
        assert stats.base_visited > 0
        assert [hit.id for hit in hits] == [hit[0] for hit in expected[:10]]
        assert [hit.score for hit in hits] == pytest.approx([hit[1] for hit in expected[:10]], abs=2e-6, rel=2e-6)


@pytest.mark.parametrize("strategy", ["average_vector", "best_score", "sum_scores"])
@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
def test_ann_updates_filters_lookup_reopen_and_arrow(tmp_path, strategy, dtype):
    schema = {"v": field(dtype=dtype), "source": VectorField(3, metric="dot")}
    vectors = [[i % 31, (i * 7) % 29, (i * 11) % 23] for i in range(128)]
    predicate = dict(kind="condition", name="keep", operator="eq", type="bool", value=True)
    with closing(Collection(tmp_path, 1, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": value},
                              fields=[PayloadField("keep", "bool", i % 2 == 0)]) for i, value in enumerate(vectors)])
        db.flush()
    with closing(Collection(tmp_path, 1)) as db:
        # Shadow old graph members in newer runs, including the source point.
        db.apply_point_batch([PointMutation.update(64, vectors={"v": [20, 1, 4]}),
                              PointMutation.delete(20), PointMutation.update(22, vectors={"v": [25, 2, 3]})])
        options = dict(strategy=strategy, filter=predicate)
        expected = db.recommend_field("v", [64, [2.5, 0, 1]], [[1, 2, 0]], 10, **options)
        hits = db.recommend_field("v", [64, [2.5, 0, 1]], [[1, 2, 0]], 10,
                                  mode="approx", ef_search=256, **options)
        assert hits == expected
        assert 64 not in [hit.id for hit in hits]
        assert 20 not in [hit.id for hit in hits]
        assert db.last_search_stats().planner_reason in ("recommendation_hnsw", "recommendation_ann_exhausted")
        arrow = recommend_field_record_batch(db, "v", [64, [2.5, 0, 1]], [[1, 2, 0]], 10,
                                              mode="approx", ef_search=256, **options)
    assert arrow.to_pydict() == {"id": [h.id for h in hits], "score": [h.score for h in hits]}


def test_custom_score_is_not_averaged_nearest_or_l2_public_distance(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": field("l2", dimension=1)})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i - 64]}) for i in range(128)])
        # Best-score gives two peaks around -50 and +50. Average-vector would
        # give a peak around zero. Sum of negative distances is a third score.
        for strategy in ("best_score", "sum_scores"):
            expected = db.recommend_field("v", [[-50], [50]], [[0]], 8, strategy=strategy)
            hits = db.recommend_field("v", [[-50], [50]], [[0]], 8, strategy=strategy,
                                      mode="approx", ef_search=128)
            assert hits == expected
            stats = db.last_search_stats()
            assert stats.planner_reason == "recommendation_hnsw"
            assert stats.distance_evaluations % 3 == 0
        best = db.recommend_field("v", [[-50], [50]], [[0]], 8, strategy="best_score", mode="approx", ef_search=128)
        assert {h.id for h in best[:2]} == {14, 114}


def test_ann_plan_bounds_empty_and_small_exact_paths(tmp_path):
    schema = {"v": field(dimension=1), "flat": VectorField(1, metric="dot")}
    with closing(Collection(tmp_path, 1, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i], "flat": [i]},
                              fields=[PayloadField("keep", "bool", i == 0)]) for i in range(128)])
        for kwargs in (dict(ef_search=0), dict(ef_search=True), dict(ef_search=10**9), dict(mode="ivf")):
            with pytest.raises(ValidationError):
                db.recommend_field("v", [[1]], **({"mode": "approx"} | kwargs))
        with pytest.raises(ValidationError):
            db.recommend_field("v", [[1]], ef_search=8)
        with pytest.raises(ValidationError, match="HNSW"):
            db.recommend_field("flat", [[1]], mode="approx")
        predicate = dict(kind="condition", name="keep", operator="eq", type="bool", value=True)
        hits = db.recommend_field("v", [[1]], mode="approx", filter=predicate)
        assert [h.id for h in hits] == [0]
        assert db.last_search_stats().planner_reason == "recommendation_selectivity"
        assert db.recommend_field("v", [0], mode="approx", filter=predicate) == []
        assert db.last_search_stats().planner_reason == "recommendation_empty"
        token = CancellationToken()
        token.cancel()
        with pytest.raises(Exception, match="cancel"):
            db.recommend_field("v", [[1]], mode="approx", cancellation=token)
        with pytest.raises(Exception, match="deadline"):
            db.recommend_field("v", [[1]], mode="approx", timeout_ns=1)
    with closing(Collection(tmp_path / "small", 1, vectors={"v": field(dimension=1)})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1]})])
        assert db.recommend_field("v", [[1]], mode="approx")[0].id == 1
        assert db.last_search_stats().planner_reason == "recommendation_small_collection"
