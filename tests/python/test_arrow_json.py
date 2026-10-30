"""Public Arrow JSON boundaries against pinned jsonb/Lance source evidence."""
from contextlib import closing
import gc
import json
import struct
from pathlib import Path

import pyarrow as pa
import pytest

from akashadb import Collection, JsonbValue, PayloadField, ValidationError
from akashadb.arrow import upsert_record_batch, upsert_point_record_batch, scan_record_batches

INGRESS = [upsert_record_batch, upsert_point_record_batch]
STORAGE = [pa.string(), pa.large_string(), pa.string_view(), pa.large_binary()]
EXT = {b"ARROW:extension:name": b"lance.json"}
FIXTURES = Path(__file__).parents[1] / "fixtures"


def _field(storage, name="data", nullable=True):
    metadata = {b"user": b"kept"}
    if storage == pa.large_binary():
        metadata.update(EXT)
        metadata[b"ARROW:extension:metadata"] = b"source has no parameters"
        dtype = storage
    else:
        dtype = pa.json_(storage)
    return pa.field(name, dtype, nullable=nullable, metadata=metadata)


def _array(values, storage):
    if storage == pa.large_binary():
        return pa.array([None if v is None else JsonbValue.from_json(v).data for v in values], type=storage)
    return pa.array(values, type=pa.json_(storage))


def _batch(array, field=None, start=0):
    field = field or pa.field("data", array.type)
    return pa.record_batch([
        pa.array(range(start, start + len(array)), type=pa.int64()),
        pa.array([[1, 2]] * len(array), type=pa.list_(pa.float32(), 2)), array,
    ], schema=pa.schema([pa.field("id", pa.int64()), pa.field("vector", pa.list_(pa.float32(), 2)), field.with_name("payload.data")]))


def _scan(db, field, **kwargs):
    return scan_record_batches(db, columns=(), payload_schema={"data": field}, **kwargs)


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("storage", STORAGE)
@pytest.mark.parametrize("flush", [False, True])
def test_source_null_contract_reopen_and_cross_storage(tmp_path, ingest, storage, flush):
    values = json.loads((FIXTURES / "lance-json/contracts.json").read_text())["arrow_nulls"]
    values += ['{z:[NaN,,],a:"漢字😀"}', "", "-0.0"]
    expected = [None if v is None else JsonbValue.from_json(v) for v in values]
    with closing(Collection(tmp_path, 2)) as db:
        ingest(db, _batch(_array(values, storage), _field(storage)))
        assert [db.get_point(i).fields[0].value for i in range(len(values))] == expected
        if flush:
            db.flush()
    with closing(Collection(tmp_path, 2)) as db:
        for target in STORAGE:
            field = _field(target)
            with _scan(db, field) as scan:
                batch = next(scan)
                batch.validate(full=True)
                assert batch.schema.equals(scan.schema, check_metadata=True)
                assert batch.schema.field(0).equals(field.with_name("payload.data"), check_metadata=True)
                actual = batch.column(0).to_pylist()
                assert actual == [None if v is None else v.data if target == pa.large_binary() else v.to_json() for v in expected]
                assert batch.column(0).is_null().to_pylist() == [True] + [False] * (len(values) - 1)
                assert scan.stats["borrowed_bytes"] == 0


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("storage", STORAGE)
@pytest.mark.parametrize("container", ["scalar", "struct", "list", "large_list", "fixed", "map"])
def test_nested_slices_nulls_and_metadata(tmp_path, ingest, storage, container):
    values = ['"unused"'] * 9 + ["null", None, '{"a":[null,"漢字😀"]}', "0"] + ['"tail"']
    child = _array(values, storage).slice(9, 4)
    field = _field(storage, "v")
    if container == "scalar":
        source, root = child, field.with_name("data")
    elif container == "struct":
        source = pa.StructArray.from_arrays([child], fields=[field], mask=pa.array([False, True, False, False]))
        root = pa.field("data", source.type)
    elif container == "fixed":
        source = pa.FixedSizeListArray.from_arrays(child, type=pa.list_(field, 2))
        root = pa.field("data", source.type)
    elif container == "map":
        dtype = pa.map_(pa.field("k", pa.int64(), nullable=False, metadata={b"key": b"meta"}), field, keys_sorted=True)
        # Non-string, duplicate keys are preserved in their original order.
        source = pa.MapArray.from_arrays([0, 2, 4], pa.array([1, 1, 2, 2]), child, type=dtype)
        root = pa.field("data", source.type)
    else:
        cls = pa.ListArray if container == "list" else pa.LargeListArray
        dtype = pa.list_(field) if container == "list" else pa.large_list(field)
        source = cls.from_arrays([0, 2, 4], child, type=dtype)
        root = pa.field("data", source.type)
    source = source.slice(1)
    with closing(Collection(tmp_path, 2)) as db:
        ingest(db, _batch(source, root))
        with _scan(db, root) as scan:
            batch = next(scan)
            batch.validate(full=True)
            assert batch.column(0).equals(source)
            # PyArrow's C Data importer canonicalizes Map child names to
            # entries/key/value; compare to the actual public producer boundary.
            expected_field = pa.Field._import_from_c_capsule(root.with_name("payload.data").__arrow_c_schema__())
            assert batch.schema.field(0).equals(expected_field, check_metadata=True)
            assert batch.schema.equals(scan.schema, check_metadata=True)


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("storage", STORAGE)
def test_invalid_cell_is_atomic_but_parent_null_masks_it(tmp_path, ingest, storage):
    dtype = _field(storage).type
    good = JsonbValue.from_json("null").data if storage == pa.large_binary() else "null"
    bad = b"broken JSONB" if storage == pa.large_binary() else '{"unterminated":'
    child = pa.array([good, bad], type=dtype)
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(9, [1, 2])
        before = (tmp_path / "wal.bin").read_bytes()
        sequence = db.last_sequence
        with pytest.raises(ValidationError):
            ingest(db, _batch(child, _field(storage)))
        assert db.last_sequence == sequence
        assert (tmp_path / "wal.bin").read_bytes() == before
        assert db.get_point(0) is None
        field = _field(storage, "value", nullable=False)
        source = pa.StructArray.from_arrays([child], fields=[field], mask=pa.array([False, True]))
        ingest(db, _batch(source))
        assert db.get_point(1).fields[0].value is None
        with _scan(db, pa.field("data", source.type)) as scan:
            batches = list(scan)
            for result in batches:
                result.validate(full=True)
            assert [v for batch in batches for v in batch.column(0).is_null().to_pylist()] == [True, False, True]


@pytest.mark.parametrize("storage", STORAGE)
def test_snapshot_empty_schema_and_child_ownership(tmp_path, storage):
    db = Collection(tmp_path, 2)
    value = JsonbValue.from_json('{"x":"long value 漢字😀"}')
    db.upsert(0, [1, 2], [PayloadField("data", "array", [None, JsonbValue.from_json("null"), value])])
    dtype = pa.list_(_field(storage, "item"))
    scan = _scan(db, pa.field("data", dtype))
    db.upsert(0, [3, 4], [PayloadField("data", "array", [])])
    db.flush()
    db.close()
    batch = next(scan)
    child = batch.column(0).values.slice(1)
    scan.close()
    del batch, scan, db
    gc.collect()
    child.validate(full=True)
    assert child.to_pylist() == ([JsonbValue.from_json("null").data, value.data] if storage == pa.large_binary() else ["null", value.to_json()])
    with closing(Collection(tmp_path / "empty", 2)) as empty:
        with _scan(empty, pa.field("data", dtype)) as scan:
            assert scan.schema == pa.schema([("payload.data", dtype)])
            assert list(scan) == []


@pytest.mark.parametrize("storage", STORAGE)
def test_required_null_type_mismatch_and_expansion_budget(tmp_path, storage):
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(0, [1, 2], [PayloadField("data", "null", None)])
        with _scan(db, _field(storage, nullable=False)) as scan:
            with pytest.raises(ValidationError, match="required"):
                next(scan)
        db.upsert(0, [1, 2], [PayloadField("data", "string", "null")])
        with _scan(db, _field(storage)) as scan:
            with pytest.raises(ValidationError, match="type mismatch"):
                next(scan)
        value = JsonbValue.from_json('"' + "\x01" * 100 + '"')
        db.upsert(0, [1, 2], [PayloadField("data", "jsonb", value)])
        scan = _scan(db, _field(storage), batch_size=1, max_batch_bytes=110)
        with pytest.raises(ValidationError, match="resource|byte"):
            next(scan)
        assert scan.closed
        with _scan(db, _field(storage), batch_size=1, max_batch_bytes=1024) as scan:
            next(scan).validate(full=True)


def test_unknown_extensions_invalid_storage_and_plain_string(tmp_path):
    fields = [pa.field("data", pa.string(), metadata=EXT),
              pa.field("data", pa.large_binary(), metadata={b"ARROW:extension:name": b"arrow.json"}),
              pa.field("data", pa.string(), metadata={b"ARROW:extension:name": b"unknown"}),
              pa.field("data", pa.large_binary())]
    with closing(Collection(tmp_path, 2)) as db:
        for field in fields:
            with pytest.raises((ValueError, ValidationError, pa.ArrowException)):
                _scan(db, field)
        upsert_record_batch(db, _batch(pa.array(["null"])))
        assert db.get_point(0).fields[0].value == "null"


def test_full_source_reader_corpus_through_arrow_and_binary_export(tmp_path):
    rows = json.loads((FIXTURES / "jsonb-text/cases.json").read_text())
    accepted = [r for r in rows if "hex" in r["extended"]]
    assert len(accepted) == 16353
    expected = [bytes.fromhex(r["extended"]["hex"]) for r in accepted]
    expected_text = [r["extended"]["text"] for r in accepted]
    with closing(Collection(tmp_path, 2)) as db:
        # Exercise both ingress routes and all canonical text storage layouts
        # on independent source-produced values, without a Python JSON codec.
        for part, start in enumerate(range(0, len(accepted), 256)):
            chunk = accepted[start:start + 256]
            storage = STORAGE[part % 3]
            source = pa.array([bytes.fromhex(r["hex"]).decode("utf-8") for r in chunk], type=pa.json_(storage))
            INGRESS[part % 2](db, _batch(source, _field(storage), start))
        with _scan(db, _field(pa.large_binary()), batch_size=256) as scan:
            actual = [v for batch in scan for v in batch.column(0).to_pylist()]
        assert actual == expected
        with _scan(db, _field(pa.string_view()), batch_size=256) as scan:
            actual_text = [v for batch in scan for v in batch.column(0).to_pylist()]
        assert actual_text == expected_text


def test_maps_preserve_entry_objects_and_reject_null_keys(tmp_path):
    with closing(Collection(tmp_path, 2)) as db:
        dtype = pa.map_(pa.int64(), pa.json_())
        source = pa.MapArray.from_arrays([0, 3], pa.array([9, 9, 1]), pa.array(["null", None, "{}"], type=pa.json_()), type=dtype)
        upsert_point_record_batch(db, _batch(source))
        assert db.get_point(0).fields[0].value == [{"key": 9, "value": JsonbValue.from_json("null")}, {"key": 9, "value": None}, {"key": 1, "value": JsonbValue.from_json("{}")}]
        db.upsert(0, [1, 2], [PayloadField("data", "array", [{"key": None, "value": None}])])
        with _scan(db, pa.field("data", dtype)) as scan:
            with pytest.raises(ValidationError, match="required"):
                next(scan)


def test_rejected_source_texts_do_not_publish(tmp_path):
    rows = json.loads((FIXTURES / "jsonb-text/cases.json").read_text())
    rejected = [r for r in rows if "error" in r["extended"]]
    assert len(rejected) == 4404
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(9, [1, 2])
        before = (tmp_path / "wal.bin").read_bytes()
        sequence = db.last_sequence
        for i, row in enumerate(rejected):
            # Retain source bytes in actual Arrow buffers. Arrow structural
            # validation rejects malformed UTF-8; Mojo parses JSON grammar.
            raw = bytes.fromhex(row["hex"])
            storage = pa.Array.from_buffers(pa.string(), 1, [None, pa.py_buffer(struct.pack("<ii", 0, len(raw))), pa.py_buffer(raw)])
            source = pa.ExtensionArray.from_storage(pa.json_(), storage)
            with pytest.raises((ValidationError, pa.ArrowInvalid)):
                INGRESS[i % 2](db, _batch(source))
        assert db.last_sequence == sequence
        assert (tmp_path / "wal.bin").read_bytes() == before
        assert db.get_point(0) is None


@pytest.mark.parametrize("ingest", INGRESS)
def test_jsonb_internal_nodes_and_combined_depth_are_bounded(tmp_path, ingest):
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(9, [1, 2])
        before = (tmp_path / "wal.bin").read_bytes()
        sequence = db.last_sequence
        # Each JSONB body is independently valid, but two such cells exceed the
        # enclosing document's aggregate node cap.
        text = "[" + ",".join(["null"] * 40000) + "]"
        value = _array([text, text], pa.string())
        source = pa.ListArray.from_arrays([0, 2], value)
        with pytest.raises(ValidationError, match="node|resource"):
            ingest(db, _batch(source))
        deep = "[" * 64 + "null" + "]" * 64
        source = pa.ListArray.from_arrays([0, 1], _array([deep], pa.string()))
        with pytest.raises(ValidationError, match="depth|nesting"):
            ingest(db, _batch(source))
        assert db.last_sequence == sequence
        assert (tmp_path / "wal.bin").read_bytes() == before


def test_all_checked_source_bodies_binary_and_text_projection(tmp_path):
    rows = json.loads((FIXTURES / "jsonb-writer/cases.json").read_text())
    accepted = [r for r in rows if "compact" in r]
    bodies = [bytes.fromhex(r["hex"]) for r in accepted]
    with closing(Collection(tmp_path, 2)) as db:
        for part, start in enumerate(range(0, len(bodies), 256)):
            source = pa.array(bodies[start:start + 256], type=pa.large_binary())
            INGRESS[part % 2](db, _batch(source, _field(pa.large_binary()), start))
        with _scan(db, _field(pa.large_binary()), batch_size=256) as scan:
            assert [v for batch in scan for v in batch.column(0).to_pylist()] == bodies
        with _scan(db, _field(pa.large_string()), batch_size=256) as scan:
            assert [v for batch in scan for v in batch.column(0).to_pylist()] == [r["compact"] for r in accepted]
        assert len(accepted) == 28901


def test_jsonb_projection_error_keeps_binary_value(tmp_path):
    # Checked binary dates may exceed Jiff's display range. Binary projection
    # remains lossless while a text projection fails without mutating storage.
    body = bytes.fromhex("20000000600000051080000000")
    with closing(Collection(tmp_path, 2)) as db:
        upsert_record_batch(db, _batch(pa.array([body], type=pa.large_binary()), _field(pa.large_binary())))
        before = (tmp_path / "wal.bin").read_bytes()
        sequence = db.last_sequence
        scan = _scan(db, _field(pa.string()))
        with pytest.raises(ValidationError):
            next(scan)
        assert scan.closed
        assert db.last_sequence == sequence
        assert (tmp_path / "wal.bin").read_bytes() == before
        with _scan(db, _field(pa.large_binary())) as scan:
            assert next(scan).column(0).to_pylist() == [body]


SOURCE_CASES = [f"{width}-{kind}" for width in ("utf8", "large") for kind in ("scalar", "struct", "list", "large-list", "fixed", "map")]


def _source_case(name, suffix):
    with pa.ipc.open_file(FIXTURES / "arrow-json" / f"{name}-{suffix}.arrow") as reader:
        batch = reader.get_batch(0)
    # Match the C Data producer boundary, including PyArrow's map-name rules.
    return pa.RecordBatch._import_from_c_capsule(*batch.__arrow_c_array__())


@pytest.mark.parametrize("name", SOURCE_CASES)
@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("source_kind", ["input", "binary"])
def test_unchanged_lance_nested_conversion_ipc(tmp_path, name, ingest, source_kind):
    source = _source_case(name, source_kind)
    with closing(Collection(tmp_path, 2)) as db:
        ingest(db, _batch(source.column(0), source.schema.field(0)))
        for target in ("binary", "text"):
            expected = _source_case(name, target)
            field = expected.schema.field(0)
            with _scan(db, field) as scan:
                batches = list(scan)
                result = pa.concat_arrays([b.column(0) for b in batches])
                result.validate(full=True)
                assert result.equals(expected.column(0))
                assert scan.schema.field(0).equals(field.with_name("payload.data"), check_metadata=True)
                for batch in batches:
                    assert batch.schema.equals(scan.schema, check_metadata=True)


@pytest.mark.parametrize("ingest", INGRESS)
@pytest.mark.parametrize("storage", STORAGE)
def test_empty_json_batch_retains_existing_rejection_without_write(tmp_path, ingest, storage):
    with closing(Collection(tmp_path, 2)) as db:
        db.upsert(9, [1, 2])
        before = (tmp_path / "wal.bin").read_bytes()
        sequence = db.last_sequence
        with pytest.raises(ValueError, match="empty|row count"):
            ingest(db, _batch(_array([], storage), _field(storage)))
        assert db.last_sequence == sequence
        assert (tmp_path / "wal.bin").read_bytes() == before
