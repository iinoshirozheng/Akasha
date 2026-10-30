from contextlib import closing
import gc
import json
from pathlib import Path
import struct

import pyarrow as pa
import pytest

from akashadb import Collection, PayloadField, ValidationError
from akashadb.arrow import upsert_record_batch, upsert_point_record_batch, scan_record_batches


FIXTURE = Path(__file__).parents[1] / "fixtures/lance-json"
INGRESS = [upsert_record_batch, upsert_point_record_batch]


def _batch(array):
    return pa.record_batch([
        pa.array(range(len(array)), type=pa.int64()),
        pa.array([[1, 2]] * len(array), type=pa.list_(pa.float32(), 2)), array,
    ], names=["id", "vector", "payload.data"])


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("flush", [False, True])
def test_original_arrow_stringview_source_roundtrip_reopen(tmp_path, ingest, flush):
    with pa.ipc.open_file(FIXTURE / "stringview.arrow") as reader:
        source = reader.get_batch(0).column(0)
    expected = json.loads((FIXTURE / "contracts.json").read_text())["stringview_values"]
    assert source.to_pylist() == expected
    assert len(source.buffers()) > 3  # actual multi-block Rust builder output
    db = Collection(tmp_path, 2)
    ingest(db, _batch(source))
    del source
    gc.collect()
    assert [db.get_point(i).fields[0].value for i in range(len(expected))] == expected
    if flush:
        db.flush()
    db.close()
    with closing(Collection(tmp_path, 2)) as reopened:
        with scan_record_batches(reopened, columns=(), payload_schema={"data": pa.string_view()}) as scan:
            batch = next(scan)
            batch.validate(full=True)
            assert batch.column(0).to_pylist() == expected
            assert scan.stats["borrowed_bytes"] == 0
            assert batch.schema.field(0).type == pa.string_view()


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("container", ["scalar", "struct", "list", "large_list", "fixed"])
def test_nested_stringview_slices_and_metadata(tmp_path, ingest, container):
    values = ["short", None, "a long string with 中文 and 😀", ""]
    child = pa.array(["unused"] * 9 + values + ["tail"], type=pa.string_view()).slice(9, 4)
    field = pa.field("s", pa.string_view(), metadata={b"label": b"view"})
    if container == "scalar":
        source = child
    elif container == "struct":
        source = pa.StructArray.from_arrays([child], fields=[field], mask=pa.array([False, True, False, False]))
    elif container == "fixed":
        source = pa.FixedSizeListArray.from_arrays(child, type=pa.list_(field, 2))
    else:
        cls = pa.ListArray if container == "list" else pa.LargeListArray
        dtype = pa.list_(field) if container == "list" else pa.large_list(field)
        source = cls.from_arrays([0, 2, 4], child, type=dtype)
    source = source.slice(1)
    with closing(Collection(tmp_path, 2)) as db:
        ingest(db, _batch(source))
        with scan_record_batches(db, columns=(), payload_schema={"data": source.type}) as scan:
            batch = next(scan)
            batch.validate(full=True)
            assert batch.column(0).equals(source)
            assert batch.schema.field(0).type.equals(source.type, check_metadata=True)


@pytest.mark.parametrize("text", ["", "x", "012345678901", "0123456789012", "😀😀😀", "😀😀😀😀", "a\0b", "a" * 10000])
def test_inline_and_external_views_follow_source_layout(tmp_path, text):
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(0, [1, 2], [PayloadField("data", "string", text)])
        with scan_record_batches(db, columns=(), payload_schema={"data": pa.string_view()}) as scan:
            array = next(scan).column(0)
            array.validate(full=True)
            buffers = array.buffers()
            view = buffers[1].to_pybytes()
            data = text.encode()
            assert struct.unpack_from("<I", view)[0] == len(data)
            if len(data) <= 12:
                assert view[4:4 + len(data)] == data
                assert view[4 + len(data):] == b"\0" * (12 - len(data))
                assert len(buffers) == 2
            else:
                assert view[4:8] == data[:4]
                index, offset = struct.unpack_from("<II", view, 8)
                assert buffers[2 + index].to_pybytes()[offset:offset + len(data)] == data
            assert array[0].as_py() == text


def test_null_empty_schema_snapshot_and_last_slice_ownership(tmp_path):
    db = Collection(tmp_path, 2)
    db.upsert(1, [1, 2], [PayloadField("data", "array", ["long captured string here", None])])
    dtype = pa.list_(pa.string_view())
    scan = scan_record_batches(db, columns=(), payload_schema={"data": dtype})
    db.upsert(1, [3, 4], [PayloadField("data", "array", ["updated"])])
    db.flush()
    db.close()
    batch = next(scan)
    child = batch.column(0).values.slice(0, 1)
    scan.close()
    del batch, scan, db
    gc.collect()
    assert child.to_pylist() == ["long captured string here"]
    child.validate(full=True)
    with closing(Collection(tmp_path / "empty", 2)) as empty:
        with scan_record_batches(empty, columns=(), payload_schema={"data": dtype}) as scan:
            assert scan.schema == pa.schema([("payload.data", dtype)])
            assert list(scan) == []


@pytest.mark.parametrize("text,budget", [("inline", 15), ("a" * 20, 47)])
def test_view_buffers_and_size_trailer_share_output_budget(tmp_path, text, budget):
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(0, [1, 2], [PayloadField("data", "string", text)])
        scan = scan_record_batches(db, batch_size=1, columns=(), payload_schema={"data": pa.string_view()}, max_batch_bytes=budget)
        with pytest.raises(ValidationError, match="resource|byte"):
            next(scan)
        assert scan.closed


def test_view_type_mismatch_and_required_null(tmp_path):
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(0, [1, 2], [PayloadField("data", "int", 2)])
        with scan_record_batches(db, columns=(), payload_schema={"data": pa.string_view()}) as scan:
            with pytest.raises(ValidationError, match="type mismatch"):
                next(scan)
        db.upsert(0, [1, 2], [PayloadField("data", "null", None)])
        with scan_record_batches(db, columns=(), payload_schema={"data": pa.field("data", pa.string_view(), nullable=False)}) as scan:
            with pytest.raises(ValidationError, match="required"):
                next(scan)
