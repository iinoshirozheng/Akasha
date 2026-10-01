import dataclasses
import json
from pathlib import Path
import struct
import subprocess
import sys

import pytest

import akashadb as db


def _schema():
    fields = {dtype: db.VectorField(2, dtype=dtype, metric="dot")
              for dtype in ("f32", "f16", "bf16", "i8", "u8")}
    fields.update({
        "bits": db.VectorField(9, dtype="binary", kind="binary", metric="jaccard"),
        "tokens": db.VectorField(2, dtype="f16", kind="multivector", metric="dot"),
        "terms": db.VectorField(0, kind="sparse", metric="dot"),
    })
    return fields


def _values():
    return {**{dtype: [2, 3] for dtype in ("f32", "f16", "bf16", "i8", "u8")},
            "bits": b"\x81\x01", "tokens": [[-1, 2], [3, 4]],
            "terms": [db.SparseElement(3, -2)]}


def _content(point):
    value = dataclasses.asdict(point)
    value.pop("sequence")
    value.pop("document_sequence")
    return value


def _source(path):
    collection = db.Collection(path, 2, vectors=_schema())
    collection.apply_point_batch([
        db.PointMutation.upsert(-7, vectors=_values()),
        db.PointMutation.upsert(2, vector=[-0.0, 2], sparse=[],
                                vectors={"tokens": [], "terms": []}),
        db.PointMutation.upsert(3, fields=[db.PayloadField("label", "string", "資料")]),
    ])
    return collection


def test_named_logical_round_trip_all_kinds_and_complete_replacement(tmp_path):
    source = _source(tmp_path / "source")
    expected = [_content(source.get_point(i)) for i in (-7, 2, 3)]
    path = tmp_path / "points.ndjson"
    assert db.export_ndjson(source, path) == 3
    source.close()
    target = db.Collection(tmp_path / "target", 2, vectors=_schema())
    target.apply_point_batch([
        db.PointMutation.upsert(3, vector=[8, 9], sparse=[db.SparseElement(1, 1)],
                                vectors=_values()),
    ])
    before = target.last_sequence
    assert db.import_ndjson(target, path) == 3
    assert target.last_sequence == before + 3
    assert [_content(target.get_point(i)) for i in (-7, 2, 3)] == expected
    target.flush()
    target.close()
    reopened = db.Collection(tmp_path / "target", 2)
    assert [_content(reopened.get_point(i)) for i in (-7, 2, 3)] == expected
    assert reopened.search_field("bits", b"\x81\x01", 1)[0].id == -7
    assert reopened.search_field("tokens", [[1, 0]], 1)[0].id == -7
    reopened.close()


@pytest.mark.parametrize("change", ["version", "schema", "count", "duplicate", "late_vector", "binary", "unknown_field", "null_named", "boolean_id"])
def test_invalid_named_import_does_not_commit_any_prefix(tmp_path, change):
    source = _source(tmp_path / "source")
    path = tmp_path / "points.ndjson"
    assert db.export_ndjson(source, path) == 3
    source.close()
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    if change == "version":
        rows[0]["version"] = 999
    elif change == "schema":
        rows[0]["vectors"]["f16"]["dtype"] = "f32"
    elif change == "count":
        rows.pop()
    elif change == "duplicate":
        rows[-1]["id"] = rows[1]["id"]
    elif change == "late_vector":
        rows[-1]["vectors"]["f16"] = [1]
    elif change == "binary":
        rows[-1]["vectors"]["bits"] = {"encoding": "hex", "data": "ffff"}
    elif change == "unknown_field":
        rows[-1]["vectors"]["missing"] = [1]
    elif change == "null_named":
        rows[-1]["vectors"]["f16"] = None
    else:
        rows[-1]["id"] = True
    path.write_text("".join(json.dumps(row) + "\n" for row in rows))
    target = db.Collection(tmp_path / "target", 2, vectors=_schema())
    target.apply_point_batch([db.PointMutation.upsert(99, vectors={"f16": [4, 5]})])
    sequence = target.last_sequence
    wal = (target.path / "wal.bin").read_bytes()
    with pytest.raises((ValueError, db.ValidationError)):
        db.import_ndjson(target, path)
    assert target.last_sequence == sequence
    assert (target.path / "wal.bin").read_bytes() == wal
    assert target.get_point(-7) is None
    assert target.get_point(99).vectors == {"f16": [4, 5]}
    target.close()


def test_export_keeps_one_captured_state_when_source_changes_and_closes(tmp_path, monkeypatch):
    source = _source(tmp_path / "source")
    expected = [_content(source.get_point(i)) for i in (-7, 2, 3)]
    original = json.dumps
    changed = False

    def write_after_capture(*args, **kwargs):
        nonlocal changed
        if not changed:
            changed = True
            source.apply_point_batch([db.PointMutation.delete(-7), db.PointMutation.delete(2)])
            source.close()
        return original(*args, **kwargs)

    monkeypatch.setattr(json, "dumps", write_after_capture)
    path = tmp_path / "points.ndjson"
    assert db.export_ndjson(source, path) == 3
    target = db.Collection(tmp_path / "target", 2, vectors=_schema())
    assert db.import_ndjson(target, path) == 3
    assert [_content(target.get_point(i)) for i in (-7, 2, 3)] == expected
    target.close()


def test_empty_point_catalog_and_empty_export_round_trip(tmp_path):
    source = db.Collection(tmp_path / "source", 2, vectors={})
    path = tmp_path / "empty.ndjson"
    assert db.export_ndjson(source, path) == 0
    source.close()
    target = db.Collection(tmp_path / "target", 2, vectors={})
    assert db.import_ndjson(target, path) == 0
    assert target.last_sequence == 0
    target.close()
    legacy = db.Collection(tmp_path / "legacy", 2)
    with pytest.raises(ValueError, match="field-aware"):
        db.import_ndjson(legacy, path)
    assert legacy.last_sequence == 0
    legacy.close()


def test_named_logical_cli_initializes_a_matching_catalog(tmp_path):
    source = _source(tmp_path / "source")
    path = tmp_path / "points.ndjson"
    assert db.export_ndjson(source, path) == 3
    source.close()
    result = subprocess.run([sys.executable, "-m", "akashadb.admin", "import",
                             str(tmp_path / "target"), "2", str(path)],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "3"
    target = db.Collection(tmp_path / "target", 2)
    assert target.vector_fields() == _schema()
    assert target.get_point(-7).vectors["bits"] == b"\x81\x01"
    target.close()


def test_native_extrema_and_signed_zero_keep_their_bits(tmp_path):
    values = {
        "f32": [struct.unpack("<f", bytes.fromhex("ffff7f7f"))[0],
                struct.unpack("<f", bytes.fromhex("01000000"))[0]],
        "f16": [65504.0, 2.0 ** -24],
        "bf16": [float.fromhex("0x1.fep+127"), 2.0 ** -133],
        "i8": [-128, 127], "u8": [0, 255],
        "tokens": [[-0.0, 0.0]],
    }
    source = db.Collection(tmp_path / "source", 2, vectors=_schema())
    source.apply_point_batch([db.PointMutation.upsert(1, vectors=values)])
    path = tmp_path / "points.ndjson"
    db.export_ndjson(source, path)
    source.close()
    target = db.Collection(tmp_path / "target", 2, vectors=_schema())
    db.import_ndjson(target, path)
    actual = target.get_point(1).vectors
    for name in ("f32", "f16", "bf16"):
        assert struct.pack("<2d", *actual[name]) == struct.pack("<2d", *values[name])
    assert struct.pack("<2d", *actual["tokens"][0]) == struct.pack("<2d", -0.0, 0.0)
    assert actual["i8"] == [-128, 127] and actual["u8"] == [0, 255]
    target.close()


def test_frozen_point_export_fixture(tmp_path):
    path = Path(__file__).parents[1] / "fixtures/logical-points/v1.ndjson"
    schema = {"bits": db.VectorField(9, kind="binary", dtype="binary", metric="hamming"),
              "tokens": db.VectorField(2, kind="multivector", dtype="bf16", metric="dot")}
    target = db.Collection(tmp_path, 2, vectors=schema)
    assert db.import_ndjson(target, path) == 2
    assert target.get_point(-5).vectors == {"bits": b"\x01\x01", "tokens": [[-0.0, 2.5]]}
    assert target.get_point(4).vector == [1.0, 2.0]
    assert target.get_point(4).sparse == []
    assert target.get_point(4).vectors == {"tokens": []}
    target.close()


@pytest.mark.parametrize("text", [
    '{"format":"akashadb.points","version":1,"version":2}\n',
    '{"id":1,"vector":[NaN,1]}\n',
    '{"id":1,"vector":[Infinity,1]}\n',
])
def test_invalid_json_never_appends_wal(tmp_path, text):
    path = tmp_path / "invalid.ndjson"
    path.write_text(text)
    target = db.Collection(tmp_path / "target", 2, vectors={})
    before = (target.path / "wal.bin").read_bytes()
    with pytest.raises(ValueError):
        db.import_ndjson(target, path)
    assert target.last_sequence == 0
    assert (target.path / "wal.bin").read_bytes() == before
    target.close()


def test_export_publish_failure_preserves_destination_and_cleans_temp(tmp_path, monkeypatch):
    source = _source(tmp_path / "source")
    destination = tmp_path / "points.ndjson"
    destination.write_bytes(b"previous export")

    def fail(*args):
        raise OSError("injected publish failure")

    monkeypatch.setattr("akashadb.operations.os.replace", fail)
    with pytest.raises(OSError, match="publish failure"):
        db.export_ndjson(source, destination)
    assert destination.read_bytes() == b"previous export"
    assert list(tmp_path.glob("points.ndjson.*.tmp")) == []
    source.close()


def test_import_row_limit_and_default_config_mismatch_are_atomic(tmp_path):
    source = _source(tmp_path / "source")
    path = tmp_path / "points.ndjson"
    db.export_ndjson(source, path)
    source.close()
    bounded = db.Collection(tmp_path / "bounded", 2, vectors=_schema(),
                            limits=db.ResourceLimits(max_batch_rows=2))
    with pytest.raises(ValueError, match="resource limit"):
        db.import_ndjson(bounded, path)
    assert bounded.last_sequence == 0
    bounded.close()
    wrong = db.Collection(tmp_path / "wrong", 2, vectors=_schema(),
                          config=db.CollectionConfig.defaults(2, ann_metric="cosine"))
    with pytest.raises(ValueError, match="schema"):
        db.import_ndjson(wrong, path)
    assert wrong.last_sequence == 0
    wrong.close()


def test_cli_rejects_existing_incompatible_catalog_without_migrating(tmp_path):
    source = _source(tmp_path / "source")
    path = tmp_path / "points.ndjson"
    db.export_ndjson(source, path)
    source.close()
    target_path = tmp_path / "target"
    target = db.Collection(target_path, 2)
    target.upsert(10, [2, 3])
    target.close()
    before = {p.name: p.read_bytes() for p in target_path.iterdir() if p.is_file() and not p.name.endswith(".cache")}
    result = subprocess.run([sys.executable, "-m", "akashadb.admin", "import",
                             str(target_path), "2", str(path)], capture_output=True, text=True)
    assert result.returncode != 0
    assert "field-aware" in result.stderr
    assert {p.name: p.read_bytes() for p in target_path.iterdir() if p.is_file() and not p.name.endswith(".cache")} == before
    target = db.Collection(target_path, 2)
    assert target.get(10).vector == [2, 3]
    assert target.last_sequence == 1
    target.close()


def test_custom_hnsw_identity_and_unsigned_seeds_round_trip(tmp_path):
    config = db.CollectionConfig.defaults(2, ann_metric="cosine", scalar_kind="bf16",
                                           level_seed=(1 << 64) - 1)
    graph = db.CollectionConfig.defaults(2, ann_metric="dot", scalar_kind="f16",
                                          level_seed=(1 << 63) + 7)
    schema = {"embedding": db.VectorField(2, dtype="f16", metric="dot", hnsw=graph)}
    source = db.Collection(tmp_path / "source", 2, config=config, vectors=schema)
    source.apply_point_batch([db.PointMutation.upsert(1, vector=[1, 0], vectors={"embedding": [2, 3]})])
    path = tmp_path / "points.ndjson"
    db.export_ndjson(source, path)
    source.close()
    target = db.Collection(tmp_path / "target", 2, config=config, vectors=schema)
    db.import_ndjson(target, path)
    assert target.collection_config() == config
    assert target.vector_fields() == schema
    assert target.search_field("embedding", [1, 0], 1, mode="approx")[0].score == 2
    target.close()
