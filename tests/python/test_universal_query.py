"""Universal plans through the public Python and Arrow boundary."""
from contextlib import closing
from dataclasses import replace
import json
from pathlib import Path

import pytest

from akashadb import (CancellationToken, Collection, CollectionConfig, MmrOptions,
                     PayloadField, PointMutation, QueryRequest, ResourceLimits,
                     SparseElement, ValidationError, VectorField)
from akashadb.arrow import query_record_batch


@pytest.fixture
def db(tmp_path):
    with closing(Collection(tmp_path, 2, vectors={"v": VectorField(2, metric="dot")})) as value:
        value.apply_point_batch([
            PointMutation.upsert(i, vectors={"v": v}, fields=[PayloadField("keep", "bool", i >= 3)])
            for i, v in enumerate([[5, 0], [4, 1], [0, 5], [1, 4], [3, 3]], 1)])
        yield value


def nearest(vector, **options):
    return QueryRequest("nearest", "v", target=vector, **options)


def sources():
    return (nearest([1, 0], limit=2), nearest([0, 1], limit=2))


def ids(hits):
    return [hit.id for hit in hits]


def test_prefetch_rescores_union_not_entire_collection(db):
    assert ids(db.query(nearest([1, 1], limit=2))) == [5, 1]
    request = nearest([1, 1], prefetch=sources(), limit=2, offset=1)
    assert ids(db.query(request)) == [2, 3]
    assert ids(db.query(replace(request, offset=0, limit=10))) == [1, 2, 3, 4]
    assert db.last_search_stats().storage_name == "query-plan"
    assert db.metrics().queries == 3


@pytest.mark.parametrize("fusion", ["rrf", "dbsf"])
def test_fusion_offsets_empty_threshold_and_owned_arrow(db, fusion):
    request = QueryRequest(fusion, prefetch=sources(), limit=10)
    hits = db.query(request)
    assert ids(hits) == [1, 3, 2, 4]
    assert db.query(replace(request, limit=2, offset=1)) == hits[1:3]
    assert db.query(replace(request, score_threshold=10)) == []
    batch = query_record_batch(db, request)
    db.close()
    assert batch.to_pydict() == {"id": ids(hits), "score": [h.score for h in hits]}


def test_parent_filter_applies_before_each_leaf_limit(db):
    predicate = dict(kind="condition", name="keep", operator="eq", type="bool", value=True)
    request = nearest([1, 1], prefetch=(nearest([1, 0], limit=1),), filter=predicate)
    assert ids(db.query(request)) == [5]
    impossible = dict(predicate, name="missing")
    assert db.query(replace(request, filter=impossible)) == []


@pytest.mark.parametrize("strategy", ["average_vector", "best_score", "sum_scores"])
def test_recommendation_rescores_only_prefetched_ids(db, strategy):
    request = QueryRequest("recommend", "v", positive=([1, 0],), negative=([0, 1],),
                           strategy=strategy, prefetch=(QueryRequest(limit=3),), limit=2)
    direct = db.recommend_field("v", [[1, 0]], [[0, 1]], 10, strategy=strategy)
    assert db.query(request) == [hit for hit in direct if hit.id <= 3][:2]


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
def test_hnsw_rescore_enforces_candidate_union_and_reopen(tmp_path, dtype):
    config = CollectionConfig(3, ann_metric="dot", m=64, m0=64, ef_construction=128)
    schema = {"v": VectorField(3, dtype=dtype, metric="dot", hnsw=config)}
    request = QueryRequest("nearest", "v", target=[1, 2, 3], prefetch=(QueryRequest(limit=96),),
                           limit=5, mode="approx", ef_search=128)
    with closing(Collection(tmp_path, 1, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i % 31, (i*7) % 29, (i*11) % 23]})
                              for i in range(128)])
        expected = db.query(replace(request, mode="exact", ef_search=None))
        assert db.query(request) == expected
        assert all(hit.id < 96 for hit in expected)
        db.flush()
    with closing(Collection(tmp_path, 1)) as db:
        assert db.query(request) == expected
        db.apply_point_batch([PointMutation.update(120, vectors={"v": [120, 120, 120]})])
        assert db.query(request) == expected


@pytest.mark.parametrize("kind", ["sparse", "multivector"])
def test_other_vector_kinds_rescore_and_fuse(tmp_path, kind):
    vectors = [[SparseElement(i, 1), SparseElement(10, i+1)] for i in range(3)] if kind == "sparse" else [
        [[1, 0]], [[0, 1]], [[1, 1], [1, 0]]]
    query = [SparseElement(10, 1)] if kind == "sparse" else [[1, 0], [0, 1]]
    field = VectorField(0 if kind == "sparse" else 2, kind=kind, metric="dot")
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        db.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": v}) for i, v in enumerate(vectors)])
        request = QueryRequest("nearest", "v", target=query, prefetch=(QueryRequest(limit=2),), limit=10)
        assert ids(db.query(request)) == ([2, 1] if kind == "sparse" else [1, 2])
        assert ids(db.query(QueryRequest("dbsf", prefetch=(request,), limit=10))) == ids(db.query(request))


def test_weighted_rrf_keeps_zero_weight_source_points(db):
    request = QueryRequest("rrf", prefetch=sources(), weights=(0, 2), limit=10)
    hits = db.query(request)
    assert ids(hits) == [3, 4, 1, 2]
    # Upstream weights compress rank positions; they do not multiply scores.
    assert [hit.score for hit in hits] == pytest.approx([2/3, 1/2, 0, 0])


def test_local_point_references_are_excluded_from_all_siblings(db):
    request = QueryRequest("rrf", prefetch=(nearest(1), nearest(3)), limit=10)
    assert set(ids(db.query(request))) == {2, 4, 5}
    assert set(ids(db.query(replace(request, prefetch=(nearest(1, lookup_from=db), nearest(3)))))) == {2, 4, 5}


def test_external_lookup_collision_is_retained(db, tmp_path):
    with closing(Collection(tmp_path / "lookup", 2, vectors={"source": VectorField(2, metric="dot")})) as source:
        source.apply_point_batch([PointMutation.upsert(1, vectors={"source": [1, 0]})])
        request = nearest(1, lookup_from=source, lookup_field="source", prefetch=sources(), limit=2)
        assert ids(db.query(request)) == [1, 2]
        source.close()
        with pytest.raises(Exception, match="closed"):
            db.query(request)


def test_nested_mmr_preserves_source_scores_and_ignores_candidate_limit(db):
    mmr = nearest([1, 1], prefetch=sources(), limit=2,
                  mmr=MmrOptions(diversity=1, candidates_limit=0), score_threshold=100)
    # A nested MMR takes ordered source results directly. Its threshold and
    # candidates_limit do not prune them (local_shard/query.rs Mmr arm).
    nested = QueryRequest("rrf", prefetch=(mmr,), limit=10)
    # Pinned Rust MMR oracle selects offsets [3, 0]: max_by_key keeps
    # the LAST equally relevant candidate, even when diversity is one.
    assert ids(db.query(nested)) == [4, 1]
    assert db.query(mmr) == []
    # A leaf prefetch carrying MMR only contributes nearest candidates.
    leaf = nearest([1, 0], limit=1, mmr=MmrOptions(diversity=1, candidates_limit=3))
    assert ids(db.query(QueryRequest("rrf", prefetch=(leaf,), limit=10))) == [1, 2, 5]


def test_root_mmr_selects_original_limit_then_applies_offset(db):
    request = nearest([1, 1], prefetch=sources(), limit=2, offset=1,
                      mmr=MmrOptions(diversity=1, candidates_limit=4))
    assert ids(db.query(request)) == [1]


def test_scroll_uses_exact_integer_ids_and_offset(db):
    db.apply_point_batch([PointMutation.upsert(2**60+1, vectors={"v": [1, 1]}),
                          PointMutation.upsert(2**60, vectors={"v": [1, 1]})])
    assert ids(db.query(QueryRequest(limit=2, offset=5))) == [2**60, 2**60+1]


def test_budget_is_shared_across_stages_and_cancellation(db):
    request = QueryRequest("rrf", prefetch=sources(), limit=10)
    db.limits = ResourceLimits(max_candidates=13)
    with pytest.raises(ValidationError, match="resource limit"):
        db.query(request)
    db.limits = ResourceLimits(max_candidates=14)
    assert len(db.query(request)) == 4
    token = CancellationToken()
    token.cancel()
    with pytest.raises(Exception, match="cancelled"):
        db.query(request, cancellation=token)
    with pytest.raises(Exception, match="deadline"):
        db.query(request, timeout_ns=1)


@pytest.mark.parametrize("invalid", [
    QueryRequest("rrf"), QueryRequest("dbsf"), QueryRequest(limit=0), QueryRequest(offset=-1),
    QueryRequest(prefetch=(QueryRequest(),)), nearest(None),
    nearest([1, 0], prefetch=(nearest([1, 0], offset=1),)),
    QueryRequest("rrf", prefetch=sources(), weights=(1,)),
    nearest([1, 0], weights=(1,)), QueryRequest(score_threshold=1),
    nearest([1, 0], score_threshold=float("nan")),
    nearest([1, 0], ef_search=4), nearest([1, 0], limit=True),
    nearest([1, 0], mode="approx", mmr=MmrOptions(candidates_limit=0)),
])
def test_invalid_queries_are_rejected(db, invalid):
    with pytest.raises(ValidationError):
        db.query(invalid)


def test_depth_bounds_and_cycle(db):
    request = QueryRequest(limit=1)
    for _ in range(64):
        request = QueryRequest("rrf", prefetch=(request,), limit=1)
    assert ids(db.query(request)) == [1]
    with pytest.raises(ValidationError, match="depth"):
        db.query(QueryRequest("rrf", prefetch=(request,)))
    cyclic = []
    cycle = QueryRequest("rrf", prefetch=cyclic)
    cyclic.append(cycle)
    with pytest.raises(ValidationError, match="cycle"):
        db.query(cycle)


@pytest.mark.parametrize("close_source", [False, True])
def test_conversion_callbacks_cannot_access_closed_handles(db, tmp_path, close_source):
    with closing(Collection(tmp_path / "lookup", 2, vectors={"v": VectorField(2, metric="dot")})) as source:
        source.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1, 0]})])
        class ClosingFloat:
            def __float__(self):
                (source if close_source else db).close()
                return 1.0
        request = nearest(1, lookup_from=source, score_threshold=ClosingFloat())
        with pytest.raises(Exception, match="closed"):
            db.query(request)


DISCOVERY = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-discovery/discovery.json").read_text())


@pytest.mark.parametrize("sample", [x for x in DISCOVERY["cases"] if x["kind"] == "dense"])
def test_nested_discovery_pipeline_matches_independent_source_scores(tmp_path, sample):
    from test_discovery import f32
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(3, metric=sample["metric"])})) as db:
        db.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": v})
                              for i, v in enumerate(sample["candidates"])])
        # ID scroll restricts discovery to a known set without another scorer
        # deciding the expected candidate membership.
        request = QueryRequest("context" if sample["target"] is None else "discover", "v",
            target=sample["target"], positive=sample["positive"], negative=sample["negative"],
            prefetch=(QueryRequest(limit=4),), limit=3)
        expected = sorted([(id, f32(bits)) for id, bits in sample["expected"] if id <= 4],
                          key=lambda h: (-h[1], h[0]))[:3]
        actual = db.query(request)
        assert ids(actual) == [h[0] for h in expected]
        assert [h.score for h in actual] == pytest.approx([h[1] for h in expected], abs=2e-6, rel=2e-6)
