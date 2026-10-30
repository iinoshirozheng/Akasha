from contextlib import closing
import gc
import json
from pathlib import Path
import struct

import numpy as np
import pyarrow as pa
import pytest

from akashadb import Collection, PayloadField, ValidationError
from akashadb.arrow import scan_record_batches, upsert_point_record_batch


def _ingest(db, array):
    batch = pa.record_batch([pa.array(range(len(array)), type=pa.int64()), array],
                            names=["id", "payload.data"])
    upsert_point_record_batch(db, batch)


@pytest.mark.parametrize("dtype,values", [
    (pa.int8(), [-128, None, 127]), (pa.int16(), [-32768, None, 32767]),
    (pa.int32(), [-2**31, None, 2**31-1]), (pa.int64(), [-2**63, None, 2**63-1]),
    (pa.uint8(), [0, None, 255]), (pa.uint16(), [0, None, 65535]),
    (pa.uint32(), [0, None, 2**32-1]), (pa.uint64(), [0, None, 2**64-1]),
    (pa.float16(), [-0.0, None, 65504]), (pa.float32(), [-0.0, None, 2**24]),
    (pa.float64(), [-0.0, None, 1.5]), (pa.bool_(), [False, None, True]),
    (pa.string(), ["", None, "中文\0😀"]), (pa.large_string(), ["", None, "中文\0😀"]),
    (pa.null(), [None, None, None]),
])
def test_typed_scalar_output_preserves_native_values(tmp_path, dtype, values):
    source = pa.array(values, type=dtype)
    with closing(Collection(tmp_path, 2)) as db:
        _ingest(db, source)
        with scan_record_batches(db, columns=(), payload_schema={"data": dtype}) as scan:
            result = next(scan)
            result.validate(full=True)
            assert result.column(0).equals(source)
            assert result.schema == pa.schema([("payload.data", dtype)])
            assert scan.stats["borrowed_bytes"] == 0
            if pa.types.is_floating(dtype):
                assert np.signbit(result.column(0)[0].as_py())


@pytest.mark.parametrize("list_type", [pa.list_, pa.large_list, lambda f: pa.list_(f, 2)])
@pytest.mark.parametrize("batch_size", [1, 3])
def test_nested_lists_structs_null_masks_and_field_metadata(tmp_path, list_type, batch_size):
    member = pa.field("n", pa.uint64(), nullable=False, metadata={b"nested": b"yes"})
    dtype = pa.struct([pa.field("items", list_type(pa.field("item", pa.struct([member]), nullable=False)))])
    source = pa.array([{"items": [{"n": 1}, {"n": 2**64-1}]}, None, {"items": None}], type=dtype)
    field = pa.field("data", dtype, nullable=True, metadata={b"label": "中文".encode()})
    with closing(Collection(tmp_path, 2)) as db:
        _ingest(db, source)
        with scan_record_batches(db, columns=(), batch_size=batch_size, payload_schema={"data": field}) as scan:
            batches = list(scan)
            for batch in batches:
                batch.validate(full=True)
                assert batch.schema.field(0).metadata == field.metadata
                assert batch.schema.field(0).type.equals(dtype, check_metadata=True)
            assert pa.Table.from_batches(batches).column(0).combine_chunks().equals(source)


@pytest.mark.parametrize("dtype,values", [
    (pa.struct([]), [{}, None, {}]),
    (pa.list_(pa.int64(), 0), [[], None, []]),
    (pa.list_(pa.null()), [[None, None], None, []]),
    (pa.large_list(pa.struct([])), [[{}, None], None, []]),
    (pa.list_(pa.field("item", pa.int64(), nullable=False), 2), [[1, 2], None, [3, 4]]),
])
def test_empty_and_required_masked_containers(tmp_path, dtype, values):
    source = pa.array(values, type=dtype)
    with closing(Collection(tmp_path, 2)) as db:
        _ingest(db, source)
        with scan_record_batches(db, columns=(), payload_schema={"data": dtype}) as scan:
            result = next(scan)
            result.validate(full=True)
            assert result.column(0).equals(source)


def test_struct_projection_has_stable_schema_and_missing_fields(tmp_path):
    dtype = pa.struct([pa.field("", pa.int64()), pa.field("name", pa.string())])
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(1, [1, 2], [PayloadField("data", "object", {"name": "a", "unused": [3]})])
        db.upsert(2, [1, 2], [PayloadField("data", "object", {"": 4})])
        db.upsert(3, [1, 2])
        with scan_record_batches(db, columns=(), payload_schema={"data": dtype}) as scan:
            assert next(scan).column(0).to_pylist() == [{"": None, "name": "a"}, {"": 4, "name": None}, None]
        for predicate in [None, {"kind": "any", "children": []}]:
            with scan_record_batches(db, columns=(), payload_schema={"data": dtype}, filter=predicate) as scan:
                assert scan.schema == pa.schema([("payload.data", dtype)])
        with closing(Collection(tmp_path / "empty", 2)) as empty:
            with scan_record_batches(empty, columns=(), payload_schema={"data": dtype}) as scan:
                assert scan.schema == pa.schema([("payload.data", dtype)])
                assert list(scan) == []


@pytest.mark.parametrize("kind,value,dtype", [
    ("int", 128, pa.int8()), ("int", -129, pa.int8()),
    ("int", 32768, pa.int16()), ("int", 2**31, pa.int32()),
    ("uint", 256, pa.uint8()), ("uint", 65536, pa.uint16()), ("uint", 2**32, pa.uint32()),
    ("float", 1e20, pa.float16()), ("float", 1e100, pa.float32()),
    ("string", "1", pa.int64()), ("int", 1, pa.float64()), ("int", 1, pa.uint64()),
    ("uint", 1, pa.int64()), ("int", 1, pa.null()),
    ("array", [1], pa.list_(pa.int64(), 2)), ("object", {}, pa.list_(pa.int64())),
    ("array", [1, "x"], pa.list_(pa.int64())),
    ("object", {"n": "x"}, pa.struct([("n", pa.int64())])),
])
def test_nested_type_and_overflow_errors_close_scanner(tmp_path, kind, value, dtype):
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(1, [1, 2], [PayloadField("data", kind, value)])
        scan = scan_record_batches(db, columns=(), payload_schema={"data": dtype})
        with pytest.raises(ValidationError):
            next(scan)
        assert scan.closed


@pytest.mark.parametrize("value,dtype", [
    (None, pa.field("data", pa.int64(), nullable=False)),
    ({}, pa.struct([pa.field("n", pa.int64(), nullable=False)])),
    ({"n": None}, pa.struct([pa.field("n", pa.int64(), nullable=False)])),
    ([None], pa.list_(pa.field("item", pa.int64(), nullable=False))),
    ([None], pa.list_(pa.field("item", pa.int64(), nullable=False), 1)),
])
def test_required_values_fail_unless_masked_by_parent(tmp_path, value, dtype):
    kind = "null" if value is None else "object" if isinstance(value, dict) else "array"
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(1, [1, 2], [PayloadField("data", kind, value)])
        scan = scan_record_batches(db, columns=(), payload_schema={"data": dtype})
        with pytest.raises(ValidationError, match="required"):
            next(scan)
        assert scan.closed


def test_owned_nested_children_survive_snapshot_mutation_and_close(tmp_path, monkeypatch):
    dtype = pa.struct([("items", pa.list_(pa.string()))])
    db = Collection(tmp_path, 2)
    _ingest(db, pa.array([{"items": ["a", None]}, None], type=dtype))
    scan = scan_record_batches(db, columns=(), payload_schema={"data": dtype})
    db.upsert(0, [1, 2], [PayloadField("data", "int", 9)])
    db.flush()
    db.close()
    # Export may only build schema/import C Data, never Python payload arrays.
    monkeypatch.setattr(pa, "array", lambda *a, **kw: (_ for _ in ()).throw(AssertionError("Python payload staging")))
    batch = next(scan)
    scan.close()
    child = batch.column(0).field(0).values.slice(0, 2)
    del batch, scan, db
    gc.collect()
    assert child.to_pylist() == ["a", None]


def test_output_budget_bounds_expanded_nulls_and_preserves_previous_batch(tmp_path):
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(0, [1, 2], [PayloadField("data", "int", 1)])
        db.upsert(1, [1, 2], [PayloadField("data", "int", 999)])
        scan = scan_record_batches(db, columns=(), batch_size=1, payload_schema={"data": pa.int8()}, max_batch_bytes=8)
        first = next(scan)
        with pytest.raises(ValidationError, match="overflow"):
            next(scan)
        assert scan.closed and first.column(0).to_pylist() == [1]
        db.upsert(0, [1, 2], [PayloadField("data", "null", None)])
        dtype = pa.list_(pa.null(), 65535)
        scan = scan_record_batches(db, columns=(), batch_size=1, payload_schema={"data": dtype}, max_batch_bytes=8,
                                   filter={"kind": "has_id", "ids": [0]})
        with pytest.raises(ValidationError, match="resource limit"):
            next(scan)
        assert scan.closed


def test_arrow_source_fixture_round_trip(tmp_path):
    fixtures = Path(__file__).parents[1] / "fixtures/rich-arrow"
    expected = json.loads((fixtures / "expected.json").read_text())
    with pa.ipc.open_stream(fixtures / "values.arrow") as reader:
        source = reader.read_next_batch()
    projection = {f.name.removeprefix("payload."): f.with_name(f.name.removeprefix("payload.")) for f in source.schema}
    source = source.add_column(0, "id", pa.array(range(source.num_rows), type=pa.int64()))
    with closing(Collection(tmp_path, 2)) as db:
        upsert_point_record_batch(db, source)
        with scan_record_batches(db, columns=(), payload_schema=projection) as scan:
            batches = list(scan)
            for batch in batches:
                batch.validate(full=True)
            table = pa.Table.from_batches(batches)
            assert table.to_pylist() == expected
            assert table.schema.equals(source.schema.remove(0), check_metadata=True)


@pytest.mark.parametrize("bits", [16, 32])
def test_arrow_source_narrowing_bits_and_finite_policy(tmp_path, bits):
    path = Path(__file__).parents[1] / "fixtures/rich-arrow-export/casts.json"
    cases = json.loads(path.read_text())
    finite_key, bits_key = f"f{bits}_finite", f"f{bits}_bits"
    values = [struct.unpack(">d", bytes.fromhex(c["f64_bits"]))[0] for c in cases]
    source = pa.record_batch([
        pa.array(range(len(cases)), type=pa.int64()), pa.array(values, type=pa.float64()),
        pa.array([c[finite_key] for c in cases]),
    ], names=["id", "payload.data", "payload.finite"])
    dtype = pa.float16() if bits == 16 else pa.float32()
    with closing(Collection(tmp_path, 2)) as db:
        upsert_point_record_batch(db, source)
        predicate = dict(kind="condition", name="finite", operator="eq", type="bool", value=True)
        actual = {}
        with scan_record_batches(db, columns=("id",), batch_size=257, payload_schema={"data": dtype}, filter=predicate) as scan:
            for batch in scan:
                array = batch.column("payload.data").to_numpy().view(np.uint16 if bits == 16 else np.uint32)
                actual.update(zip(batch.column("id").to_pylist(), [int(x) for x in array]))
        assert actual == {i: int(c[bits_key], 16) for i, c in enumerate(cases) if c[finite_key]}
        # Arrow allows nonfinite casts; Akasha's documented finite numeric
        # authority rejects each overflow instead of publishing Infinity.
        for i, case in enumerate(cases):
            if case[finite_key]:
                continue
            with scan_record_batches(db, columns=(), payload_schema={"data": dtype},
                                     filter={"kind": "has_id", "ids": [i]}) as scan:
                with pytest.raises(ValidationError, match="overflow"):
                    next(scan)
