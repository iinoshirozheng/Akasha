from contextlib import closing
import gc
import json
from pathlib import Path

import numpy as np
import pyarrow as pa
import pytest

from akashadb import Collection, PayloadField, ValidationError
from akashadb.arrow import (_validated_descriptor, upsert_record_batch,
                           upsert_point_record_batch, scan_record_batches)
from akashadb.arrow_points import point_descriptor


INGRESS = [upsert_record_batch, upsert_point_record_batch]


def _batch(array, *, nullable=True):
    count = len(array)
    return pa.RecordBatch.from_arrays([
        pa.array(range(count), type=pa.int64()),
        pa.array([[1, 2]] * count, type=pa.list_(pa.float32(), 2)), array,
    ], schema=pa.schema([("id", pa.int64()), ("vector", pa.list_(pa.float32(), 2)),
                         pa.field("payload.data", array.type, nullable=nullable)]))


def _values(db, count):
    return [db.get_point(i).fields[0].value for i in range(count)]


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("dtype,values", [
    (pa.int8(), [-128, None, 127]), (pa.int16(), [-32768, None, 32767]),
    (pa.int32(), [-2**31, None, 2**31-1]), (pa.int64(), [-2**63, None, 2**63-1]),
    (pa.uint8(), [0, None, 255]), (pa.uint16(), [0, None, 65535]),
    (pa.uint32(), [0, None, 2**32-1]), (pa.uint64(), [0, None, 2**64-1]),
    (pa.float16(), [-1.5, None, 65504]), (pa.float32(), [-1.25, None, 2**24]),
    (pa.float64(), [-0.0, None, 1.5]), (pa.bool_(), [False, None, True]),
    (pa.string(), ["", None, "中文\0😀"]), (pa.large_string(), ["", None, "中文\0😀"]),
    (pa.null(), [None, None, None]),
])
def test_typed_scalars_and_explicit_null(tmp_path, ingest, dtype, values):
    # Both bitmap and numeric data start at nonzero offsets.
    array = pa.array([values[0]] * 9 + values + [values[-1]], type=dtype).slice(9, 3)
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        ingest(db, _batch(array))
        assert _values(db, 3) == values
        if pa.types.is_unsigned_integer(dtype):
            assert db.get_point(0).fields[0].type == "uint"


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("flush", [False, True])
def test_nested_slices_nulls_and_reopen(tmp_path, ingest, flush):
    dtype = pa.struct([
        pa.field("", pa.list_(pa.struct([("n", pa.uint64()), ("s", pa.large_string())]))),
        pa.field("中文.key", pa.list_(pa.int16(), 2)),
        pa.field("empty", pa.struct([])),
    ])
    values = [{"": [{"n": 2**64-1, "s": "😀"}, None], "中文.key": [1, None], "empty": {}},
              None, {"": [], "中文.key": None, "empty": None}]
    array = pa.array([None] * 3 + values + [None], type=dtype).slice(3, 3)
    db = Collection(tmp_path, 2, vectors={})
    ingest(db, _batch(array))
    del array
    gc.collect()
    assert _values(db, 3) == values
    assert list(_values(db, 3)[0]) == ["", "中文.key", "empty"]
    if flush:
        db.flush()
    db.close()
    with closing(Collection(tmp_path, 2)) as reopened:
        assert _values(reopened, 3) == values


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("kind", ["struct", "list", "large_list", "fixed"])
def test_parent_masks_nonfinite_and_independently_sliced_children(tmp_path, ingest, kind):
    primitive = pa.array([99., 2., float("nan"), float("inf"), 5., 99.]).slice(1, 4)
    if kind == "struct":
        array = pa.StructArray.from_arrays([primitive], fields=[pa.field("n", pa.float64(), nullable=False)],
                                          mask=pa.array([False, True, True, False]))
        array = array.slice(1, 3)
        expected = [None, None, {"n": 5.}]
    elif kind == "fixed":
        array = pa.FixedSizeListArray.from_arrays(primitive, list_size=1,
                                                 mask=pa.array([False, True, True, False]))
        array = array.slice(1, 3)
        expected = [None, None, [5.]]
    else:
        cls = pa.ListArray if kind == "list" else pa.LargeListArray
        offsets = pa.array([0, 1, 3, 4], type=pa.int32() if kind == "list" else pa.int64())
        array = cls.from_arrays(offsets, primitive, mask=pa.array([False, True, False]))
        expected = [[2.], None, [5.]]
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        ingest(db, _batch(array))
        assert _values(db, 3) == expected


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("kind", ["root", "struct", "list", "fixed", "nonfinite", "duplicate"])
def test_invalid_active_value_is_atomic(tmp_path, ingest, kind):
    if kind == "root":
        batch = _batch(pa.array([1, None]), nullable=False)
    elif kind == "struct":
        dtype = pa.struct([pa.field("n", pa.int64(), nullable=False)])
        batch = _batch(pa.array([{"n": 1}, {"n": None}], type=dtype))
    elif kind in ("list", "fixed"):
        dtype = pa.list_(pa.field("item", pa.int64(), nullable=False), 1) if kind == "fixed" else pa.list_(pa.field("item", pa.int64(), nullable=False))
        batch = _batch(pa.array([[1], [None]], type=dtype))
    elif kind == "nonfinite":
        batch = _batch(pa.array([[1.0], [float("inf")]]))
    else:
        batch = _batch(pa.StructArray.from_arrays([pa.array([1, 2]), pa.array([3, 4])], names=["x", "x"]))
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        db.upsert(99, [1, 2])
        sequence = db.last_sequence
        wal = (tmp_path / "wal.bin").read_bytes()
        with pytest.raises((ValidationError, ValueError)):
            ingest(db, batch)
        assert db.last_sequence == sequence
        assert (tmp_path / "wal.bin").read_bytes() == wal
        assert db.get_point(0) is None


@pytest.mark.parametrize("named", [False, True])
def test_payload_borrows_are_native_and_detach_after_call(tmp_path, named):
    class NoPythonIndex(np.ndarray):
        def __getitem__(self, key):
            raise AssertionError("payload element was boxed in Python")

    data = np.array([1, 2, 3, 4], dtype=np.int64)
    array = pa.ListArray.from_arrays(pa.array([0, 2, 4], type=pa.int32()), pa.array(data))
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        batch = _batch(array)
        descriptor = point_descriptor(db, batch) if named else _validated_descriptor(db, batch)

        def protect(node):
            for key in ("values", "offsets", "validity"):
                if key in node:
                    node[key] = node[key].view(NoPythonIndex)
            for child in node["children"]:
                protect(child)
        protect(descriptor["payloads"][0]["array"])
        db._call("apply_point_arrow_batch" if named else "apply_arrow_batch", descriptor)
        data[:] = 99
        assert _values(db, 2) == [[1, 2], [3, 4]]


@pytest.mark.parametrize("named", [False, True])
@pytest.mark.parametrize("bad", ["offset", "dtype", "shape", "length", "validity", "children", "kind"])
def test_native_descriptor_bounds_are_failure_atomic(tmp_path, named, bad):
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        batch = _batch(pa.array([[1], [2]]))
        descriptor = point_descriptor(db, batch) if named else _validated_descriptor(db, batch)
        node = descriptor["payloads"][0]["array"]
        if bad == "offset":
            node["offsets"] = np.array([0, 1, 999], dtype=np.int32)
        elif bad == "dtype":
            node["children"][0]["values"] = np.array([1, 2], dtype=np.int32)
        elif bad == "shape":
            node["children"][0]["values"] = np.array([[1, 2]], dtype=np.int64)
        elif bad == "length":
            node["children"][0]["values"] = np.array([1], dtype=np.int64)
        elif bad == "validity":
            node["validity"] = np.array([255], dtype=np.uint8)
            node["validity_offset"] = 8
        elif bad == "children":
            node["children"] = []
        else:
            node["kind"] = 99
        with pytest.raises(ValidationError):
            db._call("apply_point_arrow_batch" if named else "apply_arrow_batch", descriptor)
        assert db.last_sequence == 0
        assert db.get_point(0) is None


@pytest.mark.parametrize("ingest", INGRESS)
def test_explicit_null_projection_and_upsert_replacement(tmp_path, ingest):
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        db.upsert(0, [1, 2], [PayloadField("old", "int", 3)])
        ingest(db, _batch(pa.array([None], type=pa.int64())))
        assert db.get_point(0).fields == [PayloadField("data", "null", None)]
        with scan_record_batches(db, columns=("id",), payload_schema={"data": "int"}) as scan:
            assert next(scan).column("payload.data").to_pylist() == [None]


@pytest.mark.parametrize("ingest", INGRESS)
def test_node_and_byte_limits_before_publication(tmp_path, ingest):
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        for array in (pa.array([list(range(65536))]), pa.array(["x" * (16 * 1024 * 1024 + 1)])):
            with pytest.raises(ValidationError, match="limit"):
                ingest(db, _batch(array))
            assert db.last_sequence == 0
        half = pa.array([list(range(40000))])
        batch = _batch(half).append_column("payload.second", half)
        with pytest.raises(ValidationError, match="node"):
            ingest(db, batch)
        assert db.last_sequence == 0


@pytest.mark.parametrize("ingest", INGRESS)
def test_nul_schema_key_is_rejected_before_c_data_truncation(tmp_path, ingest):
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        array = pa.array([{"a\0b": 1}], type=pa.struct([("a\0b", pa.int64())]))
        with pytest.raises(ValueError, match="NUL"):
            ingest(db, _batch(array))
        assert db.last_sequence == 0


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("nested", [False, True])
def test_unknown_extension_metadata_is_not_silently_discarded(tmp_path, ingest, nested):
    field = pa.field("child" if nested else "payload.data", pa.int64(),
                     metadata={b"ARROW:extension:name": b"unregistered.test.extension"})
    if nested:
        batch = _batch(pa.StructArray.from_arrays([pa.array([1])], fields=[field]))
    else:
        batch = _batch(pa.array([1])).set_column(2, field, pa.array([1]))
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        with pytest.raises(ValueError, match="extension"):
            ingest(db, batch)
        assert db.last_sequence == 0


@pytest.mark.parametrize("ingest", INGRESS)
def test_arrow_rust_source_fixture(tmp_path, ingest):
    fixtures = Path(__file__).parents[1] / "fixtures" / "rich-arrow"
    expected = json.loads((fixtures / "expected.json").read_text())
    with pa.ipc.open_stream(fixtures / "values.arrow") as reader:
        batch = reader.read_next_batch()
    ids = pa.array(range(batch.num_rows), type=pa.int64())
    vectors = pa.array([[1, 2]] * batch.num_rows, type=pa.list_(pa.float32(), 2))
    batch = batch.add_column(0, "vector", vectors).add_column(0, "id", ids)
    with closing(Collection(tmp_path, 2, vectors={})) as db:
        ingest(db, batch)
        for row, reference in enumerate(expected):
            actual = {"payload." + f.name: f.value for f in db.get_point(row).fields}
            assert actual == reference
