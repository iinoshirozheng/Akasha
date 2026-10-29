"""Native MMR integration, stable read roots, limits and Arrow ownership."""
from contextlib import closing

import pytest

from akashadb import (CancellationToken, Collection, CollectionConfig, IvfOptions,
                     MmrOptions, PayloadField, PointMutation, ResourceLimits,
                     SparseElement, ValidationError, VectorField)
from akashadb.arrow import search_field_record_batch, search_field_by_id_record_batch


ROWS = [[1, .05], [.95, .15], [.8, 0], [.85, .25], [1, .5]]


@pytest.mark.parametrize("diversity,expected", [(0, [1, 2, 3]), (.5, [1, 3, 2]), (.99, [1, 5, 4])])
@pytest.mark.parametrize("mode", ["exact", "approx", "ivf"])
def test_source_euclidean_examples_keep_original_scores(tmp_path, diversity, expected, mode):
    # Qdrant lib/shard/src/query/mmr/tests.rs::test_mmr_lambda.
    field = VectorField(2, metric="l2", hnsw=CollectionConfig.defaults(2))
    kwargs = dict(ef_search=32) if mode == "approx" else dict(ivf=IvfOptions(2, 2, 2)) if mode == "ivf" else {}
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        db.apply_point_batch([PointMutation.upsert(i + 1, vectors={"v": row}) for i, row in enumerate(ROWS)])
        original = {hit.id: hit.score for hit in db.search_field("v", [1, 0], 5)}
        hits = db.search_field("v", [1, 0], 3, mode=mode, mmr=MmrOptions(diversity, 5), **kwargs)
        assert [hit.id for hit in hits] == expected
        assert [hit.score for hit in hits] == [original[id] for id in expected]
        stats = db.last_search_stats()
        assert stats.planner_reason == "field_mmr"
        assert stats.base_candidates == 5
        assert stats.retained_candidates == 3
        batch = search_field_record_batch(db, "v", [1, 0], 3, mmr=MmrOptions(diversity, 5))
    assert batch.to_pydict() == {"id": expected, "score": [original[id] for id in expected]}


def test_ties_follow_source_swap_remove_order_and_candidate_bounds(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1, metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [1]}) for i in range(5)])
        # All scores tie; max_by_key selects the last current IndexSet entry.
        assert [h.id for h in db.search_field("v", [1], 4, mmr=MmrOptions(.5, 5))] == [4, 3, 2, 1]
        assert [h.id for h in db.search_field("v", [1], 4, mmr=MmrOptions())] == [3, 2, 1, 0]
        assert db.search_field("v", [1], 4, mmr=MmrOptions(.5, 0)) == []
        assert [h.id for h in db.search_field("v", [1], 4, mmr=MmrOptions(.5, 1))] == [0]
        assert [h.id for h in db.search_field("v", [1], 4, mmr=MmrOptions(.5, 2))] == [1, 0]
        assert [h.id for h in db.search_field("v", [1], 10, mmr=MmrOptions(.5, 10))] == [4, 3, 2, 1, 0]


@pytest.mark.parametrize("kind", ["dense", "sparse", "multivector"])
def test_filtered_point_lookup_exclusion_reopen_and_arrow(tmp_path, kind):
    schema = {"v": VectorField(0 if kind == "sparse" else 2, kind=kind, metric="dot")}
    def vector(i):
        return [SparseElement(1, i), SparseElement(2, 1)] if kind == "sparse" else [[i, 1], [1, 0]] if kind == "multivector" else [i, 1]
    keep = dict(kind="condition", name="keep", operator="eq", type="bool", value=True)
    with closing(Collection(tmp_path, 1, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": vector(i)},
                              fields=[PayloadField("keep", "bool", i < 4)]) for i in range(1, 6)])
        hits = db.search_field_by_id("v", 3, 5, filter=keep, mmr=MmrOptions(.5, 5))
        assert {h.id for h in hits} == {1, 2}
        assert len(hits) == 2
        batch = search_field_by_id_record_batch(db, "v", 3, 5, filter=keep, mmr=MmrOptions(.5, 5))
        db.flush()
    assert batch["id"].to_pylist() == [h.id for h in hits]
    with closing(Collection(tmp_path, 1)) as db:
        assert db.search_field_by_id("v", 3, 5, filter=keep, mmr=MmrOptions(.5, 5)) == hits
        db.apply_point_batch([PointMutation.delete(1), PointMutation.update(2, vectors={"v": None})])
        assert db.search_field_by_id("v", 3, 5, filter=keep, mmr=MmrOptions(.5, 5)) == []


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
def test_native_storage_types_and_external_id_collision(tmp_path, dtype, metric):
    schema = {"v": VectorField(2, dtype=dtype, metric=metric)}
    with closing(Collection(tmp_path / "target", 1, vectors=schema)) as db, \
            closing(Collection(tmp_path / "source", 1, vectors=schema)) as source:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i, 1]}) for i in range(1, 5)])
        source.apply_point_batch([PointMutation.upsert(4, vectors={"v": [4, 1]})])
        raw = db.search_field("v", [4, 1], 4, mmr=MmrOptions(.5, 4))
        external = db.search_field_by_id("v", 4, 4, lookup_from=source, mmr=MmrOptions(.5, 4))
        assert external == raw
        assert {hit.id for hit in external} == {1, 2, 3, 4}
        assert 4 not in {hit.id for hit in db.search_field_by_id("v", 4, 4, mmr=MmrOptions(.5, 4))}


@pytest.mark.parametrize("kwargs", [dict(diversity=x) for x in (-.1, 1.1, float('nan'), float('inf'), True, '0.5')] +
                         [dict(candidates_limit=x) for x in (-1, 16385, True, 1.5)])
def test_invalid_mmr_options(kwargs):
    with pytest.raises(ValueError):
        MmrOptions(**kwargs)


def test_mmr_cancellation_deadline_and_total_scoring_budget(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1)}, limits=ResourceLimits(max_candidates=4))) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i]}) for i in range(3)])
        assert len(db.search_field("v", [0], 3)) == 3
        with pytest.raises(Exception, match="candidate resource limit"):
            db.search_field("v", [0], 3, mmr=MmrOptions())
        token = CancellationToken()
        token.cancel()
        with pytest.raises(Exception, match="cancel"):
            db.search_field("v", [0], 3, mmr=MmrOptions(), cancellation=token)
        with pytest.raises(Exception, match="deadline"):
            db.search_field("v", [0], 3, mmr=MmrOptions(), timeout_ns=1)
        with pytest.raises(ValidationError, match="MmrOptions"):
            db.search_field("v", [0], 3, mmr={})


def test_binary_and_malformed_query_rejected_even_with_zero_candidates(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"b": VectorField(8, dtype="binary", kind="binary", metric="hamming"), "v": VectorField(2)})) as db:
        with pytest.raises(ValidationError, match="binary MMR"):
            db.search_field("b", b'\0', 1, mmr=MmrOptions(.5, 0))
        with pytest.raises(ValidationError):
            db.search_field("v", [1], 1, mmr=MmrOptions(.5, 0))


def test_hnsw_mmr_uses_real_graph_and_candidate_limit(tmp_path):
    config = CollectionConfig.defaults(2)
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(2, metric="l2", hnsw=config)})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i, i % 7]}) for i in range(128)])
        candidates = db.search_field("v", [30, 2], 12, mode="approx", ef_search=96)
        retrieval_stats = db.last_search_stats()
        assert retrieval_stats.base_visited > 0
        results = db.search_field("v", [30, 2], 5, mode="approx", ef_search=96, mmr=MmrOptions(.5, 12))
        assert len(results) == 5
        assert {h.id for h in results} <= {h.id for h in candidates}
        assert db.last_search_stats().base_visited == retrieval_stats.base_visited
        with pytest.raises(ValidationError, match="rerank"):
            db.search_field("v", [30, 2], 5, mode="approx", rerank_k=5, mmr=MmrOptions(.5, 12))


def test_mmr_option_conversion_rechecks_collection_ownership(tmp_path):
    db = Collection(tmp_path, 1, vectors={"v": VectorField(1)})
    class ClosingFloat:
        def __float__(self):
            db.close()
            return .5
    options = dict(mode="exact", ivf=None, mmr=dict(diversity=ClosingFloat(), candidates_limit=2))
    try:
        with pytest.raises(Exception, match="closed"):
            db._kernel.search_field("v", [1], 1, options)
    finally:
        db.close()


@pytest.mark.parametrize("field,query,kwargs", [
    (VectorField(1), [1], dict(mode="approx")),
    (VectorField(0, kind="sparse", metric="dot"), [SparseElement(1, 1)], dict(mode="approx", ef_search=32)),
    (VectorField(1, kind="multivector"), [[1]], dict(mode="approx")),
    (VectorField(0, kind="sparse", metric="dot"), [SparseElement(1, 1)], dict(mode="ivf")),
    (VectorField(1, hnsw=CollectionConfig.defaults(1)), [1], dict(mode="approx", ef_search=513)),
])
def test_zero_candidates_still_validate_index_options(tmp_path, field, query, kwargs):
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        with pytest.raises(ValidationError):
            db.search_field("v", query, 1, mmr=MmrOptions(.5, 0), **kwargs)


@pytest.mark.parametrize("field,query,mode", [
    (VectorField(1, hnsw=CollectionConfig.defaults(1)), [1], "approx"),
    (VectorField(0, kind="sparse", metric="dot"), [SparseElement(1, 1)], "approx"),
    (VectorField(1), [1], "ivf"),
])
def test_valid_zero_candidates_do_not_build_indexes(tmp_path, field, query, mode):
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": query}) for i in range(128)])
        assert db.search_field("v", query, 1, mode=mode, mmr=MmrOptions(.5, 0)) == []
        stats = db.last_search_stats()
        assert stats.distance_evaluations == 0
        assert stats.base_visited == 0
        assert stats.ivf_partitions == 0
