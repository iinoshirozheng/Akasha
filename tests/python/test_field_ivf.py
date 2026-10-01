"""Independent native-score and public IVF/Arrow/fusion acceptance tests."""

from contextlib import closing
import numpy as np
import pytest

from akashadb import Collection, FieldQuery, IvfOptions, PayloadField, PointMutation, SparseElement, ValidationError, VectorField
from akashadb.arrow import search_field_record_batch, search_fields_record_batch


@pytest.mark.parametrize("dtype", ["f32", "bf16", "f16", "i8", "u8"])
@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
def test_ivf_full_probe_native_oracle_arrow_fusion_and_reopen(tmp_path, dtype, metric):
    fields = {"x": VectorField(5, dtype=dtype, metric=metric),
              "s": VectorField(0, kind="sparse", metric="dot")}
    data = np.random.default_rng(371).integers(1, 24, size=(64, 5))
    query = [5, 6, 3, 2, 1]
    options = IvfOptions(nlist=4, nprobe=4, iterations=3)
    condition = {"kind": "condition", "name": "keep", "operator": "eq", "type": "bool", "value": True}
    with closing(Collection(tmp_path, 2, vectors=fields)) as collection:
        collection.apply_point_batch([PointMutation.upsert(i-32, vectors={
            **({"x": row.tolist()} if i % 5 else {}), "s": [SparseElement(1, i+1)]},
            fields=[PayloadField("keep", "bool", i % 3 != 0)]) for i, row in enumerate(data)])
        for filtered in (False, True):
            valid = [i for i in range(64) if i % 5 and (not filtered or i % 3)]
            scores = {}
            q = np.array(query, dtype=np.float64)
            for i in valid:
                row = data[i].astype(np.float64)
                scores[i-32] = (float(q @ row) if metric == "dot" else
                                float(np.sum((q-row)**2)) if metric == "l2" else
                                float(q @ row / (np.linalg.norm(q) * np.linalg.norm(row))))
            expected = sorted(scores, key=lambda id: (scores[id] if metric == "l2" else -scores[id], id))[:8]
            predicate = condition if filtered else None
            actual = collection.search_field("x", query, 8, filter=predicate, mode="ivf", ivf=options)
            assert [hit.id for hit in actual] == expected
            np.testing.assert_allclose([hit.score for hit in actual], [scores[id] for id in expected], rtol=1e-14)
            stats = collection.last_search_stats()
            assert stats.ivf_partitions == stats.ivf_probed_partitions == 4
            assert stats.reranked_candidates == len(valid)
            arrow = search_field_record_batch(collection, "x", query, 8, filter=predicate, mode="ivf", ivf=options)
            assert arrow["id"].to_pylist() == expected
            assert arrow["score"].to_pylist() == [hit.score for hit in actual]
        branches = [FieldQuery("x", query, mode="ivf", ivf=options), FieldQuery("s", [SparseElement(1, 1)])]
        fused = collection.search_fields(branches, 5, fetch_k=12)
        ranks = [collection.search_field("x", query, 12), collection.search_field("s", [SparseElement(1, 1)], 12)]
        rrf = {}
        for branch in ranks:
            for rank, hit in enumerate(branch, 1):
                rrf[hit.id] = rrf.get(hit.id, 0) + 1 / (60 + rank)
        assert [hit.id for hit in fused] == sorted(rrf, key=lambda id: (-rrf[id], id))[:5]
        assert search_fields_record_batch(collection, branches, 5, fetch_k=12)["score"].to_pylist() == [hit.score for hit in fused]
        collection.apply_point_batch([PointMutation.delete(-31), PointMutation.update(-30, vectors={"x": query})])
        collection.flush()
    with closing(Collection(tmp_path, 2, vectors=fields)) as collection:
        assert collection.search_field("x", query, 8, mode="ivf", ivf=options) == collection.search_field("x", query, 8)


@pytest.mark.parametrize("values", [dict(nlist=0), dict(nlist=257), dict(nlist=True),
                                   dict(nprobe=0), dict(nprobe=33), dict(nprobe=1.5),
                                   dict(iterations=0), dict(iterations=False)])
def test_ivf_options_reject_invalid_types_and_bounds(values):
    with pytest.raises(ValueError):
        IvfOptions(**values)


def test_ivf_rejects_mixed_index_controls(tmp_path):
    with closing(Collection(tmp_path, 2, vectors={"x": VectorField(2)})) as collection:
        for values in (dict(mode="exact", ivf=IvfOptions()), dict(mode="ivf", ef_search=4),
                       dict(mode="ivf", rerank_k=4), dict(mode="ivf", ivf={"nlist": 4})):
            with pytest.raises(ValidationError):
                collection.search_field("x", [1, 2], 1, **values)
        for values in (dict(mode="exact", ivf=IvfOptions()), dict(mode="ivf", ef_search=4)):
            with pytest.raises(ValueError):
                FieldQuery("x", [1, 2], **values)


def test_ivf_empty_missing_fields_and_effective_probe_bounds(tmp_path):
    with closing(Collection(tmp_path, 2, vectors={"x": VectorField(2)})) as collection:
        assert collection.search_field("x", [1, 1], 10, mode="ivf") == []
        collection.apply_point_batch([PointMutation.upsert(-1, vectors={})])
        assert collection.search_field("x", [1, 1], 10, mode="ivf") == []
        assert collection.last_search_stats().ivf_partitions == 0
        collection.apply_point_batch([PointMutation.upsert(i, vectors={"x": [i, 1]}) for i in range(3)])
        assert collection.search_field("x", [1, 1], 10, mode="ivf") == collection.search_field("x", [1, 1], 10)
        collection.search_field("x", [1, 1], 10, mode="ivf")
        stats = collection.last_search_stats()
        assert stats.ivf_partitions == stats.ivf_probed_partitions == 3
