"""Planned exact scan must match the separate single-row snapshot path."""
from contextlib import closing
import struct
import numpy as np
import pytest
from akashadb import Collection, CollectionConfig, PayloadField, PointMutation, SearchRequest, VectorField


@pytest.mark.parametrize('metric', ['dot', 'l2', 'cosine'])
def test_scan_pairs_keep_missing_fields_tails_filters_and_ties(tmp_path, metric):
    dimension = 65
    config = CollectionConfig.defaults(dimension, ann_metric=metric, max_ef_search=256)
    rng = np.random.default_rng(1953)
    rows = rng.normal(size=(13, dimension)).astype(np.float32)
    rows[1] = rows[0]
    query = rows[0].tolist()
    dense = {0, 1, 3, 5, 6, 7, 10, 12}
    def bits(hits):
        return [(hit.id, struct.pack('<f', hit.score)) for hit in hits]
    def check(collection):
        for group in (None, 0, 1, 2, 99):
            expression = None if group is None else dict(kind='condition', name='group', operator='eq', type='int', value=group)
            for k in (3, 20):
                exact = collection.search(SearchRequest(metric, k, vector=query, filter=expression))
                actual = collection.search(SearchRequest(metric, k, vector=query, filter=expression, mode='approx', ef_search=128))
                assert bits(actual) == bits(exact)
                assert collection.last_search_stats().storage_name == 'exact'
    with closing(Collection(tmp_path, dimension, config=config, vectors={'named': VectorField(1)})) as collection:
        collection.apply_point_batch([
            PointMutation.upsert(i-6, vector=rows[i].tolist() if i in dense else None, vectors={'named': [i]}, fields=[PayloadField('group', 'int', i % 3)])
            for i in range(13)
        ])
        check(collection)
        collection.apply_point_batch([
            PointMutation.delete(-5),
            PointMutation.update(-2, vector=rows[4].tolist()),
            PointMutation.update(-6, vector=None),
        ])
        check(collection)
        collection.flush()
        check(collection)
    with closing(Collection(tmp_path, dimension, config=config)) as collection:
        check(collection)
