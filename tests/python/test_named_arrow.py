import gc

import numpy as np
import pyarrow as pa
import pytest

from akashadb import Collection, PointMutation, SparseElement, VectorField
from akashadb.arrow import scan_record_batches


@pytest.mark.parametrize("dtype,arrow_type,expected", [
    ("f32", pa.float32(), [1.5, -2.0]),
    ("f16", pa.float16(), [1.5, -2.0]),
    ("bf16", pa.uint16(), [0x3FC0, 0xC000]),
    ("i8", pa.int8(), [1, -2]),
    ("u8", pa.uint8(), [1, 2]),
])
@pytest.mark.parametrize("batch_size", [1, 3])
def test_typed_arrow_buffers_nulls_and_last_owner(tmp_path, dtype, arrow_type, expected, batch_size):
    vector = [1, 2] if dtype == "u8" else [1, -2] if dtype == "i8" else [1.5, -2.0]
    collection = Collection(tmp_path, 2, vectors={"native": VectorField(2, dtype=dtype)})
    collection.apply_point_batch([
        PointMutation.upsert(1, vectors={"native": vector}),
        PointMutation.upsert(2, vector=[4, 5]),
        PointMutation.upsert(3, vectors={"native": vector}),
    ])
    scanner = scan_record_batches(collection, batch_size=batch_size,
                                  columns=("id", "sequence", "document_sequence", "vector"), vectors=("native",))
    collection.apply_point_batch([PointMutation.update(1, vectors={"native": None})])
    collection.close()
    batches = list(scanner)
    schema = scanner.schema
    scanner.close()
    del scanner, collection
    gc.collect()
    assert schema.field("vectors.native").type == pa.list_(arrow_type, 2)
    assert schema.field("vectors.native").nullable
    assert schema.field("vectors.native").metadata[b"akashadb.dtype"] == dtype.encode()
    table = pa.Table.from_batches(batches)
    table.validate(full=True)
    assert table.column("vectors.native").to_pylist() == [expected, None, expected]
    assert table.column("vector").to_pylist() == [None, [4.0, 5.0], None]
    assert table.column("sequence").to_pylist() == [1, 2, 3]
    assert table.column("document_sequence").to_pylist() == [0, 2, 0]
    if batch_size == 1:
        array = batches[0].column("vectors.native").values.slice(1)
        pointer = array.buffers()[1].address
        del table, batches
        gc.collect()
        assert array.to_pylist() == expected[1:]
        assert array.buffers()[1].address == pointer
        assert not array.to_numpy(zero_copy_only=True).flags.writeable


@pytest.mark.parametrize("batch_size", [1, 3])
def test_binary_sparse_and_multivector_arrow_preserve_empty(tmp_path, batch_size):
    fields = {
        "bits": VectorField(9, dtype="binary", kind="binary", metric="jaccard"),
        "patches": VectorField(2, dtype="f16", kind="multivector", metric="dot"),
        "terms": VectorField(0, kind="sparse", metric="dot"),
    }
    collection = Collection(tmp_path, 2, vectors=fields)
    collection.apply_point_batch([
        PointMutation.upsert(1, vectors={"bits": b"\x02\x01", "patches": [[1, 2], [3, 4]], "terms": [SparseElement(7, 0.5)]}),
        PointMutation.upsert(2, vectors={"bits": b"\x00\x00", "patches": [], "terms": []}),
        PointMutation.upsert(3),
    ])
    scanner = scan_record_batches(collection, columns=("id",), vectors=tuple(fields), batch_size=batch_size)
    collection.close()
    batches = list(scanner)
    for batch in batches:
        batch.validate(full=True)
    table = pa.Table.from_batches(batches)
    assert table.column("vectors.bits").type == pa.binary(2)
    assert table.column("vectors.bits").to_pylist() == [b"\x02\x01", b"\x00\x00", None]
    assert table.column("vectors.patches").type == pa.list_(pa.list_(pa.float16(), 2))
    assert table.column("vectors.patches").to_pylist() == [[[1.0, 2.0], [3.0, 4.0]], [], None]
    assert table.column("vectors.terms").to_pylist() == [[{"term_id": 7, "weight": 0.5}], [], None]


def test_native_arrow_ingress_sliced_buffers_atomic_and_owned(tmp_path):
    from akashadb.arrow import upsert_point_record_batch
    fields = {
        "half": VectorField(2, dtype="f16"),
        "brain": VectorField(2, dtype="bf16"),
        "byte": VectorField(2, dtype="u8"),
        "signed": VectorField(2, dtype="i8"),
        "bits": VectorField(9, dtype="binary", kind="binary", metric="hamming"),
        "multi": VectorField(2, dtype="f32", kind="multivector", metric="dot"),
        "sparse": VectorField(0, kind="sparse", metric="dot"),
    }
    collection = Collection(tmp_path, 2, vectors=fields)
    brain_type = pa.list_(pa.uint16(), 2)
    sparse_type = pa.list_(pa.struct([pa.field("term_id", pa.int64()), pa.field("weight", pa.float32())]))
    arrays = [
        pa.array([0, 1, 2, 3], type=pa.int64()),
        pa.array([[9, 9], [1.5, -2], None, [9, 9]], type=pa.list_(pa.float16(), 2)),
        pa.array([[0, 0], [0x3FC0, 0xC000], None, [0, 0]], type=brain_type),
        pa.array([[0, 0], [1, 255], None, [0, 0]], type=pa.list_(pa.uint8(), 2)),
        pa.array([[0, 0], [-128, 127], None, [0, 0]], type=pa.list_(pa.int8(), 2)),
        pa.array([b"\0\0", b"\x01\x01", None, b"\0\0"], type=pa.binary(2)),
        pa.array([[], [[1, 2], [3, 4]], [], []], type=pa.list_(pa.list_(pa.float32(), 2))),
        pa.array([[], [{"term_id": 4, "weight": 2.0}], [], []], type=sparse_type),
        pa.array(["skip", "one", None, "skip"]),
    ]
    names = ["id", "vectors.half", "vectors.brain", "vectors.byte", "vectors.signed", "vectors.bits", "vectors.multi", "vectors.sparse", "payload.label"]
    schema = pa.schema([pa.field(name, array.type, metadata={b"akashadb.dtype": b"bf16"} if name == "vectors.brain" else None) for name, array in zip(names, arrays)])
    batch = pa.record_batch(arrays, schema=schema).slice(1, 2)
    committed = upsert_point_record_batch(collection, batch)
    assert (committed.first_sequence, committed.last_sequence, committed.count) == (1, 2, 2)
    assert collection.get_point(1).vectors == {
        "half": [1.5, -2.0], "brain": [1.5, -2.0], "byte": [1, 255], "signed": [-128, 127],
        "bits": b"\x01\x01", "multi": [[1, 2], [3, 4]], "sparse": [SparseElement(4, 2.0)],
    }
    assert collection.get_point(2).vectors == {"multi": [], "sparse": []}
    # Producer can be reclaimed immediately; capture/export and restore all
    # nullable native fields through a real C Data consumer.
    del batch, arrays
    gc.collect()
    scanner = scan_record_batches(collection, columns=("id", "vector"), vectors=tuple(fields), payload_schema={"label": "string"})
    exported = next(scanner)
    copy = Collection(tmp_path / "copy", 2, vectors=fields)
    upsert_point_record_batch(copy, exported)
    assert copy.get_point(1).vectors == collection.get_point(1).vectors
    assert copy.get_point(2).vectors == collection.get_point(2).vectors
    copy.close()
    scanner.close()
    collection.close()


def test_point_arrow_null_removes_omission_preserves_and_late_error_is_atomic(tmp_path):
    from akashadb import ValidationError
    from akashadb.arrow import upsert_point_record_batch
    collection = Collection(tmp_path, 1, vectors={"a": VectorField(1, dtype="f16"), "b": VectorField(1)})
    collection.apply_point_batch([PointMutation.upsert(1, vector=[4], vectors={"a": [1], "b": [2]})])
    upsert_point_record_batch(collection, pa.record_batch([
        pa.array([1], type=pa.int64()), pa.array([None], type=pa.list_(pa.float16(), 1)),
    ], names=["id", "vectors.a"]))
    assert collection.get_point(1).vectors == {"b": [2]}
    assert collection.get_point(1).vector == [4]
    before = (tmp_path / "wal.bin").read_bytes()
    with pytest.raises((ValidationError, ValueError)):
        upsert_point_record_batch(collection, pa.record_batch([
            pa.array([1, 2], type=pa.int64()), pa.array([[9], [float("nan")]], type=pa.list_(pa.float16(), 1)),
        ], names=["id", "vectors.a"]))
    assert collection.last_sequence == 2
    assert (tmp_path / "wal.bin").read_bytes() == before
    assert collection.get_point(1).vectors == {"b": [2]}
    assert collection.get_point(2) is None
    collection.close()


def test_legacy_arrow_entrypoint_uses_one_point_batch_after_migration(tmp_path):
    from akashadb.arrow import upsert_record_batch
    collection = Collection(tmp_path, 2, vectors={})
    batch = pa.record_batch([
        pa.array([1, 2], type=pa.int64()),
        pa.array([[1, 2], [3, 4]], type=pa.list_(pa.float32(), 2)),
        pa.array([[1], [2]], type=pa.list_(pa.int64())),
        pa.array([[1], [2]], type=pa.list_(pa.float32())),
    ], names=["id", "vector", "sparse_term_ids", "sparse_weights"])
    assert upsert_record_batch(collection, batch) == 2
    assert collection.last_sequence == 2
    assert collection.get_point(1).sequence == collection.get_point(1).document_sequence == 1
    assert collection.get_point(2).sparse == [SparseElement(2, 2)]
    collection.close()


def test_native_query_arrow_score_retains_float64_precision(tmp_path):
    from akashadb.arrow import search_field_record_batch
    collection = Collection(tmp_path, 1, vectors={"v": VectorField(300, dtype="u8", metric="dot")})
    vector = np.full(300, 255, dtype=np.uint8)
    vector[-1] = 254
    collection.apply_point_batch([PointMutation.upsert(1, vectors={"v": vector})])
    query = np.full(300, 255, dtype=np.uint8)
    batch = search_field_record_batch(collection, "v", query, 1)
    collection.close()
    assert batch.column("score").type == pa.float64()
    assert batch.column("score").to_pylist() == [19_507_245.0]
    assert batch.column("id").to_pylist() == [1]


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
def test_multivector_sliced_arrow_round_trip_all_native_types(tmp_path, dtype):
    from akashadb.arrow import upsert_point_record_batch
    fields = {"v": VectorField(2, dtype=dtype, kind="multivector")}
    source = Collection(tmp_path / "source", 1, vectors=fields)
    source.apply_point_batch([
        PointMutation.upsert(i, vectors={} if i % 3 == 0 else {"v": [] if i % 3 == 1 else [[i, 2], [3, i]]})
        for i in range(19)
    ])
    scanner = scan_record_batches(source, columns=("id",), vectors=("v",), batch_size=19)
    batch = next(scanner).slice(1, 17)
    scanner.close()
    target = Collection(tmp_path / "target", 1, vectors=fields)
    upsert_point_record_batch(target, batch)
    for i in range(1, 18):
        assert target.get_point(i).vectors == source.get_point(i).vectors
    target.flush()
    target.close()
    reopened = Collection(tmp_path / "target", 1)
    assert reopened.get_point(17).vectors == {"v": [[17, 2], [3, 17]]}
    reopened.close()
    source.close()


@pytest.mark.parametrize("case", ["null_component", "null_matrix_row", "null_sparse_item", "bf16_metadata", "binary_padding"])
def test_invalid_arrow_field_never_commits_prefix(tmp_path, case):
    from akashadb import ValidationError
    from akashadb.arrow import upsert_point_record_batch
    if case == "null_component":
        spec = VectorField(2)
        values = pa.array([[1, 2], [3, None]], type=pa.list_(pa.float32(), 2))
    elif case == "null_matrix_row":
        spec = VectorField(2, kind="multivector")
        values = pa.array([[[1, 2]], [None]], type=pa.list_(pa.list_(pa.float32(), 2)))
    elif case == "null_sparse_item":
        spec = VectorField(0, kind="sparse", metric="dot")
        values = pa.array([[{"term_id": 1, "weight": 2}], [None]], type=pa.list_(pa.struct([("term_id", pa.int64()), ("weight", pa.float32())])))
    elif case == "bf16_metadata":
        spec = VectorField(2, dtype="bf16")
        values = pa.array([[0, 0], [1, 2]], type=pa.list_(pa.uint16(), 2))
    else:
        spec = VectorField(9, dtype="binary", kind="binary", metric="hamming")
        values = pa.array([b"\x01\x00", b"\x01\x80"], type=pa.binary(2))
    collection = Collection(tmp_path, 1, vectors={"v": spec})
    before = (tmp_path / "wal.bin").read_bytes()
    with pytest.raises((ValidationError, ValueError)):
        upsert_point_record_batch(collection, pa.record_batch([pa.array([1, 2], type=pa.int64()), values], names=["id", "vectors.v"]))
    assert collection.last_sequence == 0
    assert collection.get_point(1) is None
    assert (tmp_path / "wal.bin").read_bytes() == before
    collection.close()
