import gc
import weakref

import pytest
from akashadb import Collection, FieldQuery, PointMutation, SearchRequest, VectorField


class Marker:
    pass


def track_row(raw):
    marker = Marker()
    raw[0]["_ownership_marker"] = marker
    return weakref.ref(marker)


@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
@pytest.mark.parametrize("mode", ["exact", "approx"])
def test_search_rows_release_python_objects(tmp_path, metric, mode):
    c = Collection(tmp_path, 2)
    c.upsert(1001, [2.0, 1.0])
    try:
        raw = c._search_raw(SearchRequest(metric, 1, vector=[1.0, 1.0], mode=mode))
        assert raw[0]["id"] == 1001
        marker = track_row(raw)
        del raw
        gc.collect()
        assert marker() is None
    finally:
        c.close()


@pytest.mark.parametrize("filtered", [False, True])
def test_batch_releases_nested_result_lists_and_rows(tmp_path, filtered):
    c = Collection(tmp_path, 2)
    c.upsert(1001, [2.0, 1.0])
    try:
        if filtered:
            raw = c._kernel.search_batch_where("dot", [[1.0, 1.0]], [{"kind": "all", "children": []}], 1, 1)
        else:
            raw = c._kernel.search_batch("dot", [[1.0, 1.0]], 1, 1)
        marker = track_row(raw[0])
        del raw
        gc.collect()
        assert marker() is None
    finally:
        c.close()


@pytest.mark.parametrize("fusion", [False, True])
def test_named_search_releases_result_rows(tmp_path, fusion):
    c = Collection(tmp_path, 2, vectors={"v": VectorField(2)})
    c.apply_point_batch([PointMutation.upsert(1001, vectors={"v": [2.0, 1.0]})])
    try:
        if fusion:
            raw = c._search_fields_raw([FieldQuery("v", [1.0, 1.0])], 1)
        else:
            raw = c._search_field_raw("v", [1.0, 1.0], 1)
        assert raw[0]["id"] == 1001
        marker = track_row(raw)
        del raw
        gc.collect()
        assert marker() is None
    finally:
        c.close()
