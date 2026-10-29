"""Public discovery/context queries versus unedited pinned Qdrant scorers."""
from contextlib import closing
import json
import math
from pathlib import Path
import struct

import pytest

from akashadb import (CancellationToken, Collection, CollectionConfig, ContextPair,
                     PayloadField, PointMutation, ResourceLimits, SparseElement,
                     ValidationError, VectorField)
from akashadb.arrow import discover_field_record_batch

REFERENCE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-discovery/discovery.json").read_text())


def f32(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def vector(raw, kind):
    return [SparseElement(*term) for term in raw] if kind == "sparse" and raw is not None else raw


def inputs(sample):
    return dict(target=vector(sample["target"], sample["kind"]),
                context=[ContextPair(vector(p, sample["kind"]), vector(n, sample["kind"]))
                         for p, n in zip(sample["positive"], sample["negative"])])


@pytest.mark.parametrize("sample", REFERENCE["cases"])
def test_discovery_exact_scores_and_arrow_match_rust(tmp_path, sample):
    field = VectorField(sample["dimension"], kind=sample["kind"], metric=sample["metric"])
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        db.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": vector(v, sample["kind"])})
                              for i, v in enumerate(sample["candidates"])])
        hits = db.discover_field("v", **inputs(sample))
        expected = sorted([(id, f32(bits)) for id, bits in sample["expected"]], key=lambda row: (-row[1], row[0]))
        assert [h.id for h in hits] == [h[0] for h in expected]
        assert [h.score for h in hits] == pytest.approx([h[1] for h in expected], abs=2e-6, rel=2e-6)
        name = "context" if sample["target"] is None else "discovery"
        assert db.last_search_stats().backend_name == f"qdrant-{name}-f32"
        if sample["kind"] == "sparse":
            assert db.discover_field("v", mode="approx", **inputs(sample)) == hits
            assert db.last_search_stats().planner_reason == f"{name}_sparse_scored"
        arrow = discover_field_record_batch(db, "v", **inputs(sample))
    assert arrow.to_pydict() == {"id": [h.id for h in hits], "score": [h.score for h in hits]}


@pytest.mark.parametrize("sample", [s for s in REFERENCE["cases"] if s["kind"] == "dense"])
def test_discovery_hnsw_source_scores_at_full_breadth(tmp_path, sample):
    # This is scorer/stage integration, not a production graph recall claim.
    config = CollectionConfig(3, ann_metric=sample["metric"], m=128, m0=128, ef_construction=128)
    field = VectorField(3, metric=sample["metric"], hnsw=config)
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        candidates = sample["candidates"] * 16
        db.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": v}) for i, v in enumerate(candidates)])
        hits = db.discover_field("v", k=10, mode="approx", ef_search=128, **inputs(sample))
        scores = {id: f32(bits) for id, bits in sample["expected"]}
        expected = sorted([(i+1, scores[i % 7 + 1]) for i in range(len(candidates))], key=lambda row: (-row[1], row[0]))[:10]
        assert [h.id for h in hits] == [h[0] for h in expected]
        assert [h.score for h in hits] == pytest.approx([h[1] for h in expected], abs=2e-6, rel=2e-6)
        stats = db.last_search_stats()
        assert stats.planner_reason == ("context_hnsw" if sample["target"] is None else "discovery_hnsw")
        assert stats.fallback_reason == ""
        assert stats.base_visited > 0


@pytest.mark.parametrize("external", [False, True])
@pytest.mark.parametrize("target_id", [False, True])
def test_lookup_ids_exclusion_filter_and_reopen(tmp_path, external, target_id):
    schema = {"v": VectorField(1, metric="dot"), "other": VectorField(1, metric="dot", dtype="f16")}
    predicate = dict(kind="condition", name="keep", operator="eq", type="bool", value=True)
    with closing(Collection(tmp_path / "source", 1, vectors=schema)) as source:
        source.apply_point_batch([PointMutation.upsert(1, vectors={"other": [2]}),
                                  PointMutation.upsert(2, vectors={"other": [-1]})])
        with closing(Collection(tmp_path / "target", 1, vectors=schema)) as db:
            db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i], "other": [2 if i == 1 else -1]},
                                  fields=[PayloadField("keep", "bool", i < 4)]) for i in range(1, 5)])
            db.flush()
        with closing(Collection(tmp_path / "target", 1)) as db:
            lookup = source if external else db
            options = dict(target=1 if target_id else [2], context=[ContextPair(1, 2)],
                           lookup_from=lookup, lookup_field="other", filter=predicate)
            assert [h.id for h in db.discover_field("v", **options)] == ([3, 2, 1] if external else [3])
            db.apply_point_batch([PointMutation.update(3, vectors={"v": [-3]})])
            hits = db.discover_field("v", **options)
            assert hits[-1].id == 3
            assert hits[-1].score < 0
            with pytest.raises(ValidationError):
                db.discover_field("v", [2], [ContextPair(999, 2)], lookup_from=lookup, lookup_field="other")


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
@pytest.mark.parametrize("mode", ["exact", "approx"])
def test_updates_visibility_filters_and_arrow(tmp_path, dtype, mode):
    config = CollectionConfig(3, ann_metric="dot")
    schema = {"v": VectorField(3, dtype=dtype, metric="dot", hnsw=config)}
    with closing(Collection(tmp_path, 1, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i % 31, i * 7 % 29, i * 11 % 23]},
                              fields=[PayloadField("keep", "bool", i % 2 == 0)]) for i in range(128)])
        db.flush()
    with closing(Collection(tmp_path, 1)) as db:
        db.apply_point_batch([PointMutation.update(64, vectors={"v": [20, 1, 4]}),
                              PointMutation.delete(20), PointMutation.update(22, vectors={"v": [25, 2, 3]})])
        options = dict(target=[2.5, 0, 1], context=[ContextPair(64, [1, 2, 0])],
                       filter=dict(kind="condition", name="keep", operator="eq", type="bool", value=True))
        expected = db.discover_field("v", **options)
        hits = db.discover_field("v", mode=mode, ef_search=256 if mode == "approx" else None, **options)
        assert hits == expected
        assert not {20, 64}.intersection(h.id for h in hits)
        arrow = discover_field_record_batch(db, "v", mode=mode, ef_search=256 if mode == "approx" else None, **options)
    assert arrow.to_pydict() == {"id": [h.id for h in hits], "score": [h.score for h in hits]}


@pytest.mark.parametrize("context_only", [False, True])
def test_overflow_nan_ranks_above_finite_scores(tmp_path, context_only):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1, metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [0]}), PointMutation.upsert(2, vectors={"v": [2]})])
        options = dict(context=[ContextPair([-3e38], [0])]) if context_only else dict(target=[3e38])
        hits = db.discover_field("v", **options)
        assert [h.id for h in hits] == [2, 1]
        assert math.isnan(hits[0].score)
        assert math.isfinite(hits[1].score)
        arrow = discover_field_record_batch(db, "v", **options)
        assert arrow["score"].null_count == 0
        assert math.isnan(arrow["score"][0].as_py())


@pytest.mark.parametrize("context_only", [False, True])
def test_overflow_ordering_survives_two_stage_hnsw(tmp_path, context_only):
    config = CollectionConfig(1, ann_metric="dot", m=128, m0=128, ef_construction=128)
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1, metric="dot", hnsw=config)})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [0 if i % 2 == 0 else 2]}) for i in range(128)])
        options = dict(context=[ContextPair([-3e38], [0])]) if context_only else dict(target=[3e38])
        hits = db.discover_field("v", mode="approx", ef_search=128, **options)
        assert [h.id for h in hits] == list(range(1, 20, 2))
        assert all(math.isnan(h.score) for h in hits)
        assert db.last_search_stats().planner_reason == ("context_hnsw" if context_only else "discovery_hnsw")


def test_context_and_discovery_have_different_scores_and_no_l2_postprocessing(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1, metric="l2")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [-1]}), PointMutation.upsert(2, vectors={"v": [1]})])
        pairs = [ContextPair([1], [-1])]
        context = db.discover_field("v", context=pairs)
        discover = db.discover_field("v", [0], pairs)
        assert [h.id for h in context] == [2, 1]
        assert [h.score for h in context] == pytest.approx([0, -0.8])
        assert [h.score for h in discover] == pytest.approx([1.25, -0.75])


def test_validation_budgets_zero_limit_and_cancellation(tmp_path):
    schema = {"v": VectorField(1, metric="dot"), "bin": VectorField(8, kind="binary", dtype="binary", metric="hamming")}
    db = Collection(tmp_path, 1, vectors=schema, limits=ResourceLimits(max_query_batch=3, max_candidates=2))
    try:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1]}), PointMutation.upsert(2, vectors={"v": [2]})])
        for kwargs in (dict(), dict(target=True), dict(target=[1, 2]), dict(target=[float('nan')]),
                       dict(target=99), dict(target=[1], mode="approx"), dict(target=[1], mode="ivf"),
                       dict(target=[1], ef_search=4), dict(target=[1], k=-1), dict(target=[1], k=True),
                       dict(target=[1], timeout_ns=-1), dict(target=[1], lookup_field=""),
                       dict(context=[[1, 2]]), dict(context=[ContextPair([1], [2])] * 2),
                       dict(context=[ContextPair(None, [1])])):
            with pytest.raises(ValidationError):
                db.discover_field("v", **kwargs)
        with pytest.raises(ValidationError):
            db.discover_field("bin", b"\x01")
        token = CancellationToken()
        token.cancel()
        with pytest.raises(Exception, match="cancel"):
            db.discover_field("v", [1], cancellation=token)
        with pytest.raises(Exception, match="deadline"):
            db.discover_field("v", [1], timeout_ns=1)
        before = db.metrics().queries
        assert db.discover_field("missing", object(), context=object(), k=0, mode="bad", cancellation=token) == []
        assert db.last_search_stats().planner_reason == "discovery_zero_limit"
        assert db.metrics().queries >= before + 1
        assert discover_field_record_batch(db, "missing", k=0).to_pydict() == {"id": [], "score": []}
        db.apply_point_batch([PointMutation.upsert(3, vectors={"v": [3]})])
        with pytest.raises(ValidationError, match="resource"):
            db.discover_field("v", [1])
    finally:
        db.close()
    with pytest.raises(Exception, match="closed"):
        db.discover_field("v", k=0)


@pytest.mark.parametrize("close_source", [False, True])
def test_conversion_callback_cannot_use_closed_collection(tmp_path, close_source):
    schema = {"v": VectorField(1, metric="dot")}
    db = Collection(tmp_path / "target", 1, vectors=schema)
    source = Collection(tmp_path / "source", 1, vectors=schema)
    source.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1]})])

    class ClosingOptions(dict):
        def __getitem__(self, key):
            if key == "lookup_from":
                (source if close_source else db).close()
            return super().__getitem__(key)

    options = ClosingOptions(mode="exact", max_examples=3, cancelled=False, max_candidates=10,
                             deadline_ns=0, filter=None, lookup_from=source._kernel, lookup_field=None)
    try:
        with pytest.raises(Exception, match="closed"):
            db._kernel.discover_field("v", 1, [], 1, options)
    finally:
        db.close()
        source.close()
