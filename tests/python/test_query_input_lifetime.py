"""A finished named conversion must release the caller's input containers."""
import gc
import weakref
import numpy as np
import pytest
from akashadb import Collection, PointMutation, VectorField


class InputList(list):
    pass


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
@pytest.mark.parametrize("kind", ["dense", "multivector"])
@pytest.mark.parametrize("representation", ["list", "array"])
def test_query_releases_input_container(tmp_path, dtype, kind, representation):
    db = Collection(tmp_path, 2, vectors={"v": VectorField(2, dtype=dtype, kind=kind, metric="dot")})
    is_multi = kind == "multivector"
    db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [[2, 3]] if is_multi else [2, 3]})])
    options = dict(mode="exact", ivf=None, cancelled=False, deadline_ns=0,
                   max_candidates=100, ef_search=-1, rerank_k=0, filter=None)
    refs = []
    for _ in range(8):
        if representation == "list":
            row = InputList([2, 3])
            query = InputList([row]) if is_multi else row
            refs.append(weakref.ref(row))
            del row
        else:
            # BF16 takes the existing numeric conversion path without a new
            # optional dependency; all other arrays exercise matching dtype.
            numpy_dtype = {"f32": "float32", "f16": "float16", "bf16": "float32", "i8": "int8", "u8": "uint8"}[dtype]
            query = np.array([[2, 3]] if is_multi else [2, 3], dtype=numpy_dtype)
        refs.append(weakref.ref(query))
        result = db._kernel.search_field("v", query, 1, options)
        assert result[0]["id"] == 1 and result[0]["score"] == 13
        del query
    gc.collect()
    assert all(ref() is None for ref in refs), "finished conversion retained its input"
    assert db.get_point(1).vectors["v"] == ([[2, 3]] if is_multi else [2, 3])
    db.close()


@pytest.mark.parametrize("failure", ["dimension", "scalar"])
def test_invalid_query_releases_input_container(tmp_path, failure):
    db = Collection(tmp_path, 2, vectors={"v": VectorField(2, metric="dot")})
    db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [2, 3]})])
    options = dict(mode="exact", ivf=None, cancelled=False, deadline_ns=0,
                   max_candidates=100, ef_search=-1, rerank_k=0, filter=None)
    query = InputList([2] if failure == "dimension" else [2, True])
    ref = weakref.ref(query)
    try:
        db._kernel.search_field("v", query, 1, options)
    except Exception as error:
        assert ("dimension" if failure == "dimension" else "real numbers") in str(error)
    else:
        pytest.fail("invalid query succeeded")
    del query
    gc.collect()
    assert ref() is None, "failed conversion retained its input"
    assert db.last_sequence == 1
    db.close()


@pytest.mark.parametrize("behavior", ["accept", "error", "close"])
def test_dtype_callback_preserves_effect_and_releases_input(tmp_path, behavior):
    db = Collection(tmp_path, 2, vectors={"v": VectorField(2, metric="dot")})
    db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [2, 3]})])
    events = []
    class DtypeList(InputList):
        @property
        def dtype(self):
            events.append("dtype")
            if behavior == "error": raise ValueError("dtype callback sentinel")
            if behavior == "close": db.close()
            return "not-an-array"
    query = DtypeList([2, 3])
    ref = weakref.ref(query)
    options = dict(mode="exact", ivf=None, cancelled=False, deadline_ns=0,
                   max_candidates=100, ef_search=-1, rerank_k=0, filter=None)
    failure = None
    try:
        result = db._kernel.search_field("v", query, 1, options)
    except Exception as error:
        failure = str(error)
    if behavior == "accept":
        assert failure is None, failure
        assert result[0]["id"] == 1 and result[0]["score"] == 13
    else:
        expected = "dtype callback sentinel" if behavior == "error" else "collection is closed"
        assert failure and expected in failure
    assert events == ["dtype"]
    del query
    gc.collect()
    assert ref() is None
    db.close()


@pytest.mark.parametrize("representation", ["list", "array"])
def test_write_releases_input_and_owns_committed_values(tmp_path, representation):
    db = Collection(tmp_path, 2, vectors={"v": VectorField(2, metric="dot")})
    value = InputList([2, 3]) if representation == "list" else np.array([2, 3], dtype=np.float32)
    ref = weakref.ref(value)
    db._kernel.apply_point_batch([dict(operation="upsert", id=1,
        updates=[dict(name="v", value=value)], fields=None)])
    value[0] = 99
    assert db.get_point(1).vectors["v"] == [2, 3]
    del value
    gc.collect()
    assert ref() is None
    db.flush()
    db.close()
    db = Collection(tmp_path, 2, vectors={"v": VectorField(2, metric="dot")})
    assert db.get_point(1).vectors["v"] == [2, 3]
    db.close()


def test_only_none_means_remove_field(tmp_path):
    events = []
    class EqualToNoneType(type):
        def __eq__(cls, other):
            events.append("type-equality")
            return other is type(None)
        __hash__ = type.__hash__
    class SpoofedList(InputList, metaclass=EqualToNoneType):
        pass
    db = Collection(tmp_path, 2, vectors={"v": VectorField(2, metric="dot")})
    query = SpoofedList([2, 3])
    db._kernel.apply_point_batch([dict(operation="upsert", id=1,
        updates=[dict(name="v", value=query)], fields=None)])
    assert db.get_point(1).vectors["v"] == [2, 3]
    assert events == []
    db._kernel.apply_point_batch([dict(operation="update", id=1,
        updates=[dict(name="v", value=None)], fields=None)])
    assert "v" not in db.get_point(1).vectors
    db.close()
