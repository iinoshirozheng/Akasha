"""Public score/filter/recovery contract when approximate requests plan a scan."""

import numpy as np
import pytest
from contextlib import closing

from akashadb import (
    BatchMutation, Collection, CollectionConfig, PayloadField, PointMutation,
    SearchRequest, VectorField,
)


@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
def test_cost_scan_preserves_scores_filters_updates_and_reopen(tmp_path, metric):
    config = CollectionConfig.defaults(128, ann_metric=metric, m=24, m0=48,
                                       ef_construction=64, max_ef_search=256)
    rng = np.random.default_rng(1921)
    vectors = rng.normal(size=(96, 128)).astype(np.float32)
    query = vectors[0].tolist()
    expression = {"kind": "condition", "name": "group", "operator": "eq",
                  "type": "int", "value": 1}
    with closing(Collection(tmp_path, 128, config=config)) as collection:
        collection.apply_batch([BatchMutation.upsert(i - 50, row.tolist(),
            [PayloadField("group", "int", i % 4)]) for i, row in enumerate(vectors)])
        collection.apply_batch([BatchMutation.delete(-49),
            BatchMutation.upsert(-45, query, [PayloadField("group", "int", 1)])])
        for condition in (None, expression):
            exact = collection.search(SearchRequest(metric, 3, vector=query, filter=condition))
            actual = collection.search(SearchRequest(metric, 3, vector=query, mode="approx",
                                                       ef_search=128, filter=condition))
            assert actual == exact
            stats = collection.last_search_stats()
            assert stats.fallback_reason == "scan_cost"
            assert stats.storage_name == "exact"
            assert stats.distance_evaluations == (95 if condition is None else 23)
        collection.flush()
    with closing(Collection(tmp_path, 128, config=config)) as collection:
        exact = collection.search(SearchRequest(metric, 3, vector=query, filter=expression))
        assert collection.search(SearchRequest(metric, 3, vector=query, mode="approx",
                                                ef_search=128, filter=expression)) == exact
        assert collection.last_search_stats().fallback_reason == "scan_cost"


@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
def test_default_scan_skips_absent_fields_after_point_updates_and_reopen(tmp_path, metric):
    config = CollectionConfig.defaults(128, ann_metric=metric, max_ef_search=256)
    query = [1.0] + [0.0] * 127
    other = [0.0, 1.0] + [0.0] * 126
    payload = [PayloadField("group", "int", 1)]
    expression = {"kind": "condition", "name": "group", "operator": "eq",
                  "type": "int", "value": 1}
    expected = {"dot": [(1, 1.0), (2, 0.0)],
                "l2": [(1, 0.0), (2, 2.0)],
                "cosine": [(1, 1.0), (2, 0.0)]}[metric]

    def check(collection):
        for condition in (None, expression):
            for mode in ("exact", "approx"):
                hits = collection.search(SearchRequest(
                    metric, 8, vector=query, mode=mode, ef_search=128,
                    filter=condition,
                ))
                assert [(hit.id, hit.score) for hit in hits] == expected
                if mode == "approx":
                    assert collection.last_search_stats().storage_name == "exact"

    with closing(Collection(tmp_path, 128, config=config,
                            vectors={"named": VectorField(1)})) as collection:
        collection.apply_point_batch([
            PointMutation.upsert(1, vector=query, vectors={"named": [3]}, fields=payload),
            PointMutation.upsert(2, vectors={"named": [4]}, fields=payload),
            PointMutation.upsert(-3, vectors={"named": [5]}, fields=payload),
            PointMutation.upsert(4, sparse=[], fields=payload),
            PointMutation.upsert(5, vector=query, fields=payload),
            PointMutation.upsert(6, vector=query, fields=payload),
        ])
        collection.apply_point_batch([
            PointMutation.update(2, vector=other),
            PointMutation.update(5, vector=None),
            PointMutation.delete(6),
        ])
        check(collection)
        collection.flush()
    with closing(Collection(tmp_path, 128, config=config)) as collection:
        check(collection)
