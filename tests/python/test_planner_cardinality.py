"""Cardinality routing preserves public scores through updates and reopen."""

import numpy as np
import pytest
from contextlib import closing

from akashadb import BatchMutation, Collection, CollectionConfig, PayloadField, SearchRequest


@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
def test_cardinality_plan_preserves_scores_filters_updates_and_reopen(tmp_path, metric):
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
            assert stats.fallback_reason == ""
            assert stats.storage_name.startswith("segmented-")
            # The mutable-only population fits ef, so every admitted ID goes
            # directly to authoritative scoring without preliminary distances.
            assert stats.distance_evaluations == 0
            assert stats.reranked_candidates == (95 if condition is None else 23)
            assert stats.delta_candidates == stats.reranked_candidates
        collection.flush()
    with closing(Collection(tmp_path, 128, config=config)) as collection:
        exact = collection.search(SearchRequest(metric, 3, vector=query, filter=expression))
        assert collection.search(SearchRequest(metric, 3, vector=query, mode="approx",
                                                ef_search=128, filter=expression)) == exact
        assert collection.last_search_stats().fallback_reason == ""
