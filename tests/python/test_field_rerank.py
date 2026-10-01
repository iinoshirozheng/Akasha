"""Bounded candidate selection with independent native final-score oracles."""

from contextlib import closing

import numpy as np
import pytest

from akashadb import Collection, CollectionConfig, FieldQuery, IvfOptions, PayloadField, PointMutation, ResourceLimits, ValidationError, VectorField
from akashadb.arrow import search_fields_record_batch


@pytest.mark.parametrize("mode", ["exact", "approx", "ivf"])
@pytest.mark.parametrize("kind,metric,dtype", [("binary", "hamming", "binary"), ("binary", "jaccard", "binary")] +
                         [("multivector", metric, dtype) for metric in ("dot", "l2", "cosine") for dtype in ("f32", "f16", "bf16", "i8", "u8")])
def test_native_rerank_candidate_bound_oracle_arrow_mutations_and_reopen(tmp_path, mode, kind, metric, dtype):
    rng = np.random.default_rng(187)
    tokens = rng.integers(1, 8, size=(48, 3, 3))
    packed = [bytes([i * 5 % 256]) for i in range(48)]
    query = bytes([53]) if kind == "binary" else [[1, 2, 3], [3, 1, 1]]
    fields = {"candidate": VectorField(2, metric="dot", hnsw=CollectionConfig.defaults(2, ann_metric="dot")),
              "final": VectorField(8 if kind == "binary" else 3, dtype=dtype, kind=kind, metric=metric)}
    values = {i-24: (packed[i] if kind == "binary" else tokens[i].tolist()) for i in range(48) if i % 7}
    options = IvfOptions(nlist=4, nprobe=4, iterations=3) if mode == "ivf" else None
    branches = [FieldQuery("candidate", [1., 0.], mode=mode, ivf=options,
                           ef_search=64 if mode == "approx" else None)]
    rerank = FieldQuery("final", query)
    predicate = {"kind": "condition", "name": "keep", "operator": "eq", "type": "bool", "value": True}

    def expected(deleted=()):
        candidates = [i-24 for i in reversed(range(48)) if i % 2 == 0 and i-24 not in deleted][:15]
        scores = {}
        for id in candidates:
            if id not in values or values[id] == []:
                continue
            if kind == "binary":
                q, v = query[0], values[id][0]
                scores[id] = float((q ^ v).bit_count()) if metric == "hamming" else 1. - (q & v).bit_count() / (q | v).bit_count()
            else:
                q, v = np.array(query), np.array(values[id])
                if metric == "cosine":
                    q = q / np.linalg.norm(q, axis=1)[:, None]
                    v = v / np.linalg.norm(v, axis=1)[:, None]
                scores[id] = (float(np.min(np.sum((q[:, None, :] - v[None, :, :])**2, axis=2), axis=1).sum())
                              if metric == "l2" else float(np.max(q @ v.T, axis=1).sum()))
        ordered = sorted(scores, key=lambda id: (scores[id] if kind == "binary" or metric == "l2" else -scores[id], id))[:5]
        return ordered, [scores[id] for id in ordered]

    def verify(collection, deleted=()):
        actual = collection.search_fields(branches, 5, fetch_k=15, filter=predicate, rerank=rerank)
        ids, scores = expected(deleted)
        assert [hit.id for hit in actual] == ids
        np.testing.assert_allclose([hit.score for hit in actual], scores, rtol=2e-14)
        stats = collection.last_search_stats()
        assert stats.storage_name == "field-rerank"
        assert stats.base_candidates == 15
        assert stats.retained_candidates == len(ids)
        arrow = search_fields_record_batch(collection, branches, 5, fetch_k=15, filter=predicate, rerank=rerank)
        assert arrow["id"].to_pylist() == ids
        assert arrow["score"].to_pylist() == [hit.score for hit in actual]

    with closing(Collection(tmp_path, 2, vectors=fields)) as collection:
        collection.apply_point_batch([PointMutation.upsert(i-24,
            vectors={"candidate": [float(i), 1.], **({"final": values[i-24]} if i-24 in values else {})},
            fields=[PayloadField("keep", "bool", i % 2 == 0)]) for i in range(48)])
        verify(collection)
        values[20] = query if kind == "binary" else []
        collection.apply_point_batch([PointMutation.delete(22), PointMutation.update(20, vectors={"final": values[20]})])
        verify(collection, deleted=(22,))
        collection.flush()
    with closing(Collection(tmp_path, 2)) as collection:
        verify(collection, deleted=(22,))


def test_rerank_validates_before_empty_results_and_enforces_total_budget(tmp_path):
    fields = {"candidate": VectorField(2), "final": VectorField(2, kind="multivector")}
    with closing(Collection(tmp_path, 2, vectors=fields, limits=ResourceLimits(max_candidates=4))) as collection:
        branch = [FieldQuery("candidate", [1, 1])]
        for final in (FieldQuery("missing", [1, 1]), FieldQuery("final", [[1]]),
                      FieldQuery("final", [[1, 1]], mode="ivf")):
            with pytest.raises(ValidationError):
                collection.search_fields(branch, 1, fetch_k=2, rerank=final)
        collection.apply_point_batch([PointMutation.upsert(i, vectors={"candidate": [1, 1], "final": [[1, 1]]}) for i in range(3)])
        with pytest.raises(ValidationError, match="resource limit"):
            collection.search_fields(branch, 1, fetch_k=2, rerank=FieldQuery("final", [[1, 1]]))
