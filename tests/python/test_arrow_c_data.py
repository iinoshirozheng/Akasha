import gc

import pyarrow as pa
import pytest

import akashadb
from akashadb.arrow import (
    ArrowBatchLease,
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
