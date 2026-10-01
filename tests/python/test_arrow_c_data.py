import gc
import weakref

import numpy as np
import pyarrow as pa
import pytest

import akashadb
import akashadb.arrow as arrow
from akashadb.arrow import (
    ArrowBatchLease,
    _primitive_view,
    _validated_descriptor,
    results_to_record_batch,
    upsert_record_batch,
)


def _batch() -> pa.RecordBatch:
    vectors = pa.FixedSizeListArray.from_arrays(
        pa.array([1.0, 0.0, 0.0, 1.0], type=pa.float32()), 2
    )
    return pa.record_batch(
        [
            pa.array([10, 20], type=pa.int64()),
            vectors,
            pa.array([[7, 9], [7]], type=pa.list_(pa.int64())),
            pa.array([[2.0, 0.5], [1.0]], type=pa.list_(pa.float32())),
            pa.array(["first", "second"], type=pa.string()),
            pa.array([3, None], type=pa.int64()),
            pa.array([0.5, 1.5], type=pa.float64()),
            pa.array([True, False], type=pa.bool_()),
        ],
        names=[
            "id",
            "vector",
            "sparse_term_ids",
            "sparse_weights",
            "payload.chunk",
            "payload.page",
            "payload.weight",
            "payload.visible",
        ],
    )


def test_c_data_lease_and_typed_batch_round_trip(tmp_path) -> None:
    source = _batch()
    lease = ArrowBatchLease.from_producer(source)
    del source
    gc.collect()

    collection = akashadb.Collection(tmp_path / "arrow-c", 2)
    written = upsert_record_batch(collection, lease)
    assert written == 2
    assert collection.get(10).vector == [1.0, 0.0]
    assert {field.name: field.value for field in collection.get(10).fields} == {
        "chunk": "first",
        "page": 3,
        "weight": 0.5,
        "visible": True,
    }
    assert {field.name: field.value for field in collection.get(20).fields} == {
        "chunk": "second",
        "weight": 1.5,
        "visible": False,
    }
    sparse = collection.search(
        akashadb.SearchRequest(
            "dot", 2, sparse=[akashadb.SparseElement(9, 1.0)], mode="sparse"
        )
    )
    assert [item.id for item in sparse] == [10]

    lease.release()
    assert lease.released
    sequence_after_success = collection.last_sequence
    with pytest.raises(RuntimeError, match="released"):
        upsert_record_batch(collection, lease)
    assert collection.last_sequence == sequence_after_success
    with pytest.raises(RuntimeError, match="released exactly once"):
        lease.release()
    collection.close()
    reopened = akashadb.Collection(tmp_path / "arrow-c", 2)
    assert reopened.get(10).vector == [1.0, 0.0]
    assert reopened.search(akashadb.SearchRequest(
        "dot", 2, sparse=[akashadb.SparseElement(9, 1.0)], mode="sparse"
    ))[0].id == 10
    reopened.close()


def test_invalid_schema_and_dimension_are_failure_atomic(tmp_path) -> None:
    collection = akashadb.Collection(tmp_path / "arrow-invalid", 2)
    collection.upsert(1, [1.0, 1.0])
    baseline_sequence = collection.last_sequence

    wrong_vectors = pa.FixedSizeListArray.from_arrays(
        pa.array([1.0, 2.0, 3.0], type=pa.float32()), 3
    )
    wrong = pa.record_batch(
        [pa.array([2], type=pa.int64()), wrong_vectors],
        names=["id", "vector"],
    )
    with pytest.raises(ValueError, match="dimension"):
        upsert_record_batch(collection, wrong)

    bad_sparse = _batch().set_column(
        3,
        "sparse_weights",
        pa.array([[2.0], [1.0]], type=pa.list_(pa.float32())),
    )
    with pytest.raises(ValueError, match="sparse"):
        upsert_record_batch(collection, bad_sparse)

    assert collection.last_sequence == baseline_sequence
    assert collection.get(2) is None
    collection.close()


def test_sliced_batch_projection_and_owned_result_export(tmp_path) -> None:
    collection = akashadb.Collection(tmp_path / "arrow-slice", 2)
    batch = pa.concat_batches([_batch(), _batch()]).slice(1, 2)
    assert upsert_record_batch(collection, batch) == 2

    projected = collection.get(20, projection=akashadb.Projection(False, ("chunk",)))
    assert projected.vector == []
    assert [(field.name, field.value) for field in projected.fields] == [
        ("chunk", "second")
    ]

    results = collection.search(
        akashadb.SearchRequest("dot", 2, vector=[1.0, 0.0])
    )
    exported = results_to_record_batch(results)
    collection.close()
    assert exported.schema == pa.schema(
        [pa.field("id", pa.int64()), pa.field("score", pa.float32())]
    )
    assert exported.column("id").to_pylist() == [10, 20]


def test_real_buffers_parent_and_independent_child_offsets(tmp_path):
    ids = np.arange(8, dtype=np.int64)
    values = np.arange(20, dtype=np.float32)
    terms = np.arange(20, dtype=np.int64)
    weights = np.arange(1, 21, dtype=np.float32)
    offsets = pa.array([0, 2, 4, 6, 8], type=pa.int32())
    batch = pa.record_batch([
        pa.array(ids).slice(2, 4),
        pa.FixedSizeListArray.from_arrays(pa.array(values).slice(3, 8), 2),
        pa.ListArray.from_arrays(offsets, pa.array(terms).slice(2, 8)),
        pa.ListArray.from_arrays(offsets, pa.array(weights).slice(5, 8)),
    ], names=["id", "vector", "sparse_term_ids", "sparse_weights"]).slice(1, 2)
    collection = akashadb.Collection(tmp_path / "child-slices", 2)
    descriptor = _validated_descriptor(collection, batch)
    for key, original, offset in [
        ("ids", ids, 3), ("vectors", values, 5),
        ("sparse_terms", terms, 2), ("sparse_weights", weights, 5),
    ]:
        view = descriptor[key]
        assert view.ctypes.data == original.ctypes.data + offset * original.itemsize
        assert np.shares_memory(view, original)
        assert view.flags.c_contiguous and not view.flags.writeable
    assert descriptor["sparse_offsets"].ctypes.data == offsets.buffers()[1].address + 4
    assert upsert_record_batch(collection, batch) == 2
    assert collection.get(3).vector == [5.0, 6.0]
    assert collection.get(4).vector == [7.0, 8.0]
    assert collection.search(akashadb.SearchRequest(
        "dot", 2, sparse=[akashadb.SparseElement(4, 1.0)], mode="sparse"
    ))[0].score == 8.0
    # Mutation after the synchronous borrow ends cannot change accepted data.
    values[:] = -100
    weights[:] = -100
    del descriptor, batch, ids, values, terms, weights
    gc.collect()
    assert collection.get(3).vector == [5.0, 6.0]
    collection.close()
    reopened = akashadb.Collection(tmp_path / "child-slices", 2)
    assert reopened.get(4).vector == [7.0, 8.0]
    assert reopened.search(akashadb.SearchRequest(
        "dot", 2, sparse=[akashadb.SparseElement(4, 1.0)], mode="sparse"
    ))[0].score == 8.0
    reopened.close()


@pytest.mark.parametrize("key,value", [
    ("ids", np.array([10, 20], dtype=np.int32)),
    ("vectors", np.arange(4, dtype=np.float64)),
    ("vectors", np.arange(8, dtype=np.float32)[::2]),
    ("vectors", np.arange(4, dtype=np.float32).reshape(2, 2)),
    ("vectors", np.arange(3, dtype=np.float32)),
    ("sparse_offsets", np.array([0, 2, 99], dtype=np.int32)),
    ("sparse_offsets", np.array([0, 2, 2], dtype=np.int32)),
    ("sparse_terms", np.array([7, 9], dtype=np.int64)),
    ("sparse_weights", np.array([2.0, 0.5, np.nan], dtype=np.float32)),
])
def test_native_borrow_rejects_bad_layout_and_values_before_any_write(tmp_path, key, value):
    collection = akashadb.Collection(tmp_path / "bad-borrow", 2)
    descriptor = _validated_descriptor(collection, _batch())
    descriptor[key] = value
    sequence = collection.last_sequence
    with pytest.raises(akashadb.ValidationError):
        collection._call("apply_arrow_batch", descriptor)
    assert collection.last_sequence == sequence
    assert collection.get(10) is None
    collection.close()


@pytest.mark.parametrize("column,array", [
    ("id", pa.array([10, None], type=pa.int64())),
    ("vector", pa.array([[1.0, None], [0.0, 1.0]], type=pa.list_(pa.float32(), 2))),
    ("sparse_term_ids", pa.array([[7, None], [7]], type=pa.list_(pa.int64()))),
    ("sparse_weights", pa.array([[2.0, 0.0], [1.0]], type=pa.list_(pa.float32()))),
    ("sparse_term_ids", pa.array([[9, 7], [7]], type=pa.list_(pa.int64()))),
])
def test_arrow_nulls_and_invalid_sparse_values_preserve_preflight_error(tmp_path, column, array):
    collection = akashadb.Collection(tmp_path / "nulls", 2)
    source = _batch()
    source = source.set_column(source.schema.get_field_index(column), column, array)
    with pytest.raises(ValueError):
        upsert_record_batch(collection, source)
    assert collection.last_sequence == 0
    collection.close()


def test_primitive_slice_bounds_are_not_silently_clipped():
    array = pa.array([1, 2], type=pa.int64())
    for start, count in [(-1, 1), (0, -1), (1, 2)]:
        with pytest.raises(ValueError, match="bounds"):
            _primitive_view(array, start, count)


def test_kernel_primitive_loop_never_indexes_python_arrays(tmp_path):
    class NoPythonIndex(np.ndarray):
        def __getitem__(self, key):
            raise AssertionError("primitive loop crossed back into Python")

    collection = akashadb.Collection(tmp_path / "no-boxing", 2)
    descriptor = _validated_descriptor(collection, _batch())
    for key in ["ids", "vectors", "sparse_offsets", "sparse_terms", "sparse_weights"]:
        descriptor[key] = descriptor[key].view(NoPythonIndex)
    assert collection._call("apply_arrow_batch", descriptor) == 2
    assert collection.get(20).vector == [0.0, 1.0]
    collection.close()


@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
@pytest.mark.parametrize("mode", ["exact", "approx", "sparse", "hybrid"])
@pytest.mark.parametrize("filtered", [False, True])
def test_direct_result_columns_match_all_search_modes(tmp_path, metric, mode, filtered):
    collection = akashadb.Collection(tmp_path / "result-columns", 2)
    for point in range(80):
        collection.upsert(point - 40, [float(point + 1), 1.0], fields=[
            akashadb.PayloadField("keep", "bool", point % 2 == 0),
        ])
        collection.upsert_sparse(point - 40, [akashadb.SparseElement(7, float(point + 1))])
    request = akashadb.SearchRequest(
        metric, 12, vector=[1.0, 0.5], mode=mode,
        sparse=[akashadb.SparseElement(7, 1.0)], ef_search=96,
        filter={"kind": "condition", "name": "keep", "operator": "eq", "type": "bool", "value": True}
        if filtered else None,
    )
    expected = collection.search(request)
    before = collection.metrics().queries
    actual = arrow.search_record_batch(collection, request)
    assert collection.metrics().queries == before + 1
    assert actual.schema == pa.schema([("id", pa.int64()), ("score", pa.float32())])
    assert actual.column("id").to_pylist() == [row.id for row in expected]
    np.testing.assert_array_equal(actual.column("score").to_numpy(), np.array([row.score for row in expected], dtype=np.float32))
    collection.close()


def test_direct_result_owns_typed_buffers_through_last_slice(tmp_path, monkeypatch):
    collection = akashadb.Collection(tmp_path / "result-owner", 2)
    ids = [-(2**63), -1, 0, 2**63 - 1]
    for point in reversed(ids):
        collection.upsert(point, [1.0, 1.0])
    request = akashadb.SearchRequest("dot", 4, vector=[1.0, 1.0])
    arrays = []
    empty = np.empty

    def capture_empty(*args, **kwargs):
        array = empty(*args, **kwargs)
        arrays.append(array)
        return array

    def forbidden_row(*args, **kwargs):
        raise AssertionError("direct Arrow output constructed a Python SearchResult")

    monkeypatch.setattr(np, "empty", capture_empty)
    monkeypatch.setattr("akashadb.database.SearchResult", forbidden_row)
    batch = arrow.search_record_batch(collection, request)
    assert len(arrays) == 2
    assert arrays[0].dtype == np.int64 and arrays[1].dtype == np.float32
    assert sum(array.nbytes for array in arrays) == 12 * len(ids)
    assert batch.column(0).buffers()[1].address == arrays[0].ctypes.data
    assert batch.column(1).buffers()[1].address == arrays[1].ctypes.data
    owners = [weakref.ref(array) for array in arrays]
    sliced = batch.slice(1, 2)
    arrays.clear()
    collection.close()
    del batch, collection
    gc.collect()
    assert all(owner() is not None for owner in owners)
    assert sliced.column("id").to_pylist() == [-1, 0]
    assert sliced.column("score").to_pylist() == [2.0, 2.0]
    del sliced
    gc.collect()
    assert all(owner() is None for owner in owners)


def test_direct_result_empty_and_validation_match_search(tmp_path):
    collection = akashadb.Collection(tmp_path / "result-empty", 2)
    request = akashadb.SearchRequest("dot", 5, vector=[1.0, 0.0])
    batch = arrow.search_record_batch(collection, request)
    assert batch.num_rows == 0
    assert batch.schema == pa.schema([("id", pa.int64()), ("score", pa.float32())])
    for invalid in [
        akashadb.SearchRequest("dot", 0, vector=[1.0, 0.0]),
        akashadb.SearchRequest("dot", 1),
        akashadb.SearchRequest("dot", 1, vector=[1.0]),
        akashadb.SearchRequest("dot", 10001, vector=[1.0, 0.0]),
    ]:
        with pytest.raises(akashadb.ValidationError):
            arrow.search_record_batch(collection, invalid)
    collection.close()
    with pytest.raises(akashadb.CollectionClosedError):
        arrow.search_record_batch(collection, request)
