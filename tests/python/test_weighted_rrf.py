"""Weighted field retrieval checked against unedited native Qdrant fusion."""

from contextlib import closing
import json
import math
from pathlib import Path
import struct

import pytest

from akashadb import (CancellationToken, Collection, CollectionConfig, FieldQuery,
                     IvfOptions, PayloadField, PointMutation, ResourceLimits,
                     SparseElement, ValidationError, VectorField)
from akashadb.arrow import search_fields_record_batch


FIXTURE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-rrf/weighted.json").read_text())


def f32(raw):
    return struct.unpack("<f", struct.pack("<I", raw))[0]


def bits(value):
    return struct.unpack("<I", struct.pack("<f", value))[0]


# Zero-branch and duplicate-within-branch inputs exercise the low-level native
# utility; actual field retrieval returns distinct IDs and requires a branch.
FIELD_CASES = [sample for sample in FIXTURE["cases"] if sample["branches"]
               and all(len(set(branch)) == len(branch) for branch in sample["branches"])]


@pytest.mark.parametrize("sample", FIELD_CASES)
def test_field_fusion_matches_rust_bits(tmp_path, sample):
    queries = [FieldQuery("s", [SparseElement(term + 1, 1.0)])
               for term in range(len(sample["branches"]))]
    points = {}
    for term, branch in enumerate(sample["branches"]):
        for rank, id in enumerate(branch):
            points.setdefault(id, []).append(SparseElement(term + 1, len(branch) - rank))
    weights = None if sample["weight_bits"] is None else list(map(f32, sample["weight_bits"]))
    with closing(Collection(tmp_path, 1, vectors={"s": VectorField(0, kind="sparse", metric="dot")})) as db:
        if points:
            db.apply_point_batch([PointMutation.upsert(id, vectors={"s": terms}) for id, terms in points.items()])
        options = dict(fetch_k=100, rank_constant=sample["rank_constant"], weights=weights)
        if "error" in sample:
            with pytest.raises(ValidationError, match="weights"):
                db.search_fields(queries, 100, **options)
            return
        if any(not math.isfinite(f32(hit[1])) for hit in sample["expected"]):
            with pytest.raises(ValidationError, match="finite Float32"):
                db.search_fields(queries, 100, **options)
            return
        hits = db.search_fields(queries, 100, **options)
        assert [[hit.id, bits(hit.score)] for hit in hits] == sample["expected"]
        assert db.last_search_stats().metric_name == "rrf"
        arrow = search_fields_record_batch(db, queries, 100, **options)
        assert arrow.to_pydict() == {"id": [hit.id for hit in hits], "score": [hit.score for hit in hits]}


def test_filter_weighted_candidate_rerank_arrow_and_reopen(tmp_path):
    fields = {"a": VectorField(1, metric="dot"), "b": VectorField(1, metric="dot"),
              "final": VectorField(1, metric="l2")}
    queries = [FieldQuery("a", [1.0]), FieldQuery("b", [1.0])]
    predicate = {"kind": "condition", "name": "keep", "operator": "eq", "type": "bool", "value": True}
    # This exact ranking is the frozen two-source [3,1] fixture.
    sample = next(s for s in FIXTURE["cases"] if s["branches"] == [[1, 2], [2, 1]]
                  and s["weight_bits"] == [bits(3.0), bits(1.0)])

    def verify(db):
        hits = db.search_fields(queries, 2, fetch_k=2, weights=[3.0, 1.0], filter=predicate)
        assert [[hit.id, bits(hit.score)] for hit in hits] == sample["expected"]
        arrow = search_fields_record_batch(db, queries, 2, fetch_k=2, weights=[3.0, 1.0], filter=predicate)
        assert arrow["score"].to_pylist() == [hit.score for hit in hits]
        # At fetch_k=1 only the heavier source's first result survives fusion.
        reranked = db.search_fields(queries, 1, fetch_k=1, weights=[3.0, 1.0],
                                   filter=predicate, rerank=FieldQuery("final", [0.0]))
        assert [(hit.id, hit.score) for hit in reranked] == [(1, 4.0)]
        assert db.last_search_stats().storage_name == "field-rerank"
        assert db.search_fields(queries, 2) == db.search_fields(queries, 2, weights=[1.0, 1.0])
        return arrow

    with closing(Collection(tmp_path, 1, vectors=fields)) as db:
        db.apply_point_batch([
            PointMutation.upsert(1, vectors={"a": [2.0], "b": [1.0], "final": [2.0]}, fields=[PayloadField("keep", "bool", True)]),
            PointMutation.upsert(2, vectors={"a": [1.0], "b": [2.0], "final": [1.0]}, fields=[PayloadField("keep", "bool", True)]),
            PointMutation.upsert(3, vectors={"a": [999.0], "b": [999.0]}, fields=[PayloadField("keep", "bool", False)]),
        ])
        arrow = verify(db)
        db.flush()
    assert arrow["id"].to_pylist() == [hit[0] for hit in sample["expected"]]
    with closing(Collection(tmp_path, 1)) as db:
        verify(db)


@pytest.mark.parametrize("mode", ["approx", "ivf"])
def test_weights_apply_after_ann_and_ivf_ranking(tmp_path, mode):
    config = CollectionConfig.defaults(1, ann_metric="dot")
    field = VectorField(1, metric="dot", hnsw=config)
    options = dict(ef_search=64) if mode == "approx" else dict(ivf=IvfOptions(nlist=4, nprobe=4, iterations=2))
    queries = [FieldQuery("v", [1.0], mode=mode, **options), FieldQuery("v", [-1.0], mode=mode, **options)]
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i + 1.0]}) for i in range(64)])
        rankings = [db.search_field("v", vector, 2, mode=mode, **options)
                    for vector in ([1.0], [-1.0])]
        assert rankings[0][0].id != rankings[1][0].id
        # Disjoint first choices: weight selects which branch wins; zero-weight
        # choices remain in the result rather than silently disappearing. ANN
        # may return different candidates from exhaustive search; fusion must
        # consume its actual rankings, without silently switching search mode.
        assert [hit.id for hit in db.search_fields(queries, 1, fetch_k=1, weights=[3.0, 1.0])] == [rankings[0][0].id]
        assert [hit.id for hit in db.search_fields(queries, 1, fetch_k=1, weights=[1.0, 3.0])] == [rankings[1][0].id]
        hits = db.search_fields(queries, 2, fetch_k=2, weights=[0.0, -1.0])
        retained_ids = sorted({hit.id for ranking in rankings for hit in ranking})[:2]
        assert [(hit.id, hit.score) for hit in hits] == [(id, 0.0) for id in retained_ids]
        stats = db.last_search_stats()
        if mode == "approx":
            assert stats.effective_ef >= 64
        else:
            assert stats.ivf_probed_partitions == 8


@pytest.mark.parametrize("weights", [[], [1.0, 2.0], "1", [float("nan")],
                                    [float("inf")], [-float("inf")], [1e100]])
def test_invalid_weights_rejected_on_empty_collection(tmp_path, weights):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1)})) as db:
        with pytest.raises(ValidationError, match="weights|Float32"):
            db.search_fields([FieldQuery("v", [1.0])], 1, weights=weights)


def test_native_validation_cannot_be_bypassed_and_dbsf_rejects_weights(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1)})) as db:
        query = FieldQuery("v", [1.0])
        options = dict(k=1, fetch_k=1, rank_constant=2, fusion="rrf", rerank=None,
                       filter=None, cancelled=False, deadline_ns=0, max_candidates=100)
        for weights in ([], [1.0, 2.0], [float("nan")], [float("inf")]):
            with pytest.raises(Exception, match="weights"):
                db._kernel.search_fields([query.to_kernel()], dict(options, weights=weights))
        for weights in ([], [1.0]):
            with pytest.raises(ValidationError, match="weights require RRF"):
                db.search_fields([query], 1, fusion="dbsf", weights=weights)
            with pytest.raises(Exception, match="weights require RRF"):
                db._kernel.search_fields([query.to_kernel()], dict(options, fusion="dbsf", weights=weights))


def test_zero_weights_keep_cancellation_and_branch_budgets(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1)}, limits=ResourceLimits(max_candidates=1))) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1.0]})])
        queries = [FieldQuery("v", [1.0])] * 2
        with pytest.raises(Exception, match="candidate resource limit"):
            db.search_fields(queries, 1, weights=[0.0, 0.0])
        token = CancellationToken()
        token.cancel()
        with pytest.raises(Exception, match="cancel"):
            db.search_fields(queries, 1, weights=[0.0, 0.0], cancellation=token)
