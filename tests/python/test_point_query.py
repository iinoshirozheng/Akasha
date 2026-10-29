"""Stored-point lookup/exclusion versus native upstream reference decisions."""

from contextlib import closing
import json
from pathlib import Path

import pytest

from akashadb import (CancellationToken, Collection, CollectionConfig, IvfOptions,
                     PayloadField, PointMutation, ResourceLimits, SparseElement,
                     ValidationError, VectorField)
from akashadb.arrow import search_field_by_id_record_batch


FIXTURE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-point-lookup/lookup.json").read_text())


@pytest.mark.parametrize("sample", FIXTURE["cases"])
def test_lookup_and_exclusion_match_qdrant_rust(tmp_path, sample):
    schema = {"v": VectorField(2, metric="dot"), "alternate": VectorField(2, metric="dot")}
    with closing(Collection(tmp_path / "target", 1, vectors=schema)) as target, \
            closing(Collection(tmp_path / "other", 1, vectors=schema)) as other, \
            closing(Collection(tmp_path / "missing", 1, vectors=schema)) as missing:
        target.apply_point_batch([
            PointMutation.upsert(1, vectors={"v": [1, 2], "alternate": [2, 1]}),
            PointMutation.upsert(2, vectors={"v": [-1, 3]}), PointMutation.upsert(3, vectors={}),
        ])
        other.apply_point_batch([
            PointMutation.upsert(1, vectors={"v": [9, 8], "alternate": [8, 9]}),
            PointMutation.upsert(2, vectors={"v": [4, 5]}),
        ])
        lookup = {None: None, "target": target, "other": other, "missing": missing}[sample["lookup_collection"]]
        kwargs = dict(lookup_from=lookup, lookup_field=sample["lookup_field"])
        if sample["resolved"] is None:
            with pytest.raises(ValidationError, match="lookup|vector"):
                target.search_field_by_id("v", sample["id"], 2, **kwargs)
        else:
            # Scoring is the unchanged native search. Only lookup and candidate
            # exclusion are new here and their decisions come from Rust.
            expected = [hit for hit in target.search_field("v", sample["resolved"], 10)
                        if hit.id not in sample["excluded"]][:2]
            hits = target.search_field_by_id("v", sample["id"], 2, **kwargs)
            assert hits == expected
            arrow = search_field_by_id_record_batch(target, "v", sample["id"], 2, **kwargs)
            assert arrow.to_pydict() == {"id": [h.id for h in hits], "score": [h.score for h in hits]}


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
@pytest.mark.parametrize("kind", ["dense", "multivector"])
@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
def test_native_typed_vectors_reopen_filter_and_arrow(tmp_path, dtype, kind, metric):
    schema = {"v": VectorField(2, dtype=dtype, kind=kind, metric=metric)}
    rows = [[1, 4], [2, 3], [3, 2], [4, 1]]
    vectors = [[row, row[::-1]] for row in rows] if kind == "multivector" else rows
    predicate = dict(kind="condition", name="keep", operator="eq", type="bool", value=True)

    def verify(db):
        # The source is excluded by the payload predicate; lookup still finds it.
        expected = db.search_field("v", vectors[0], 3, filter=predicate)
        hits = db.search_field_by_id("v", -1, 3, filter=predicate)
        assert hits == expected
        assert len(hits) == 3
        assert db.search_field_by_id("v", -1, 3, lookup_from=db, filter=predicate) == hits
        arrow = search_field_by_id_record_batch(db, "v", -1, 3, filter=predicate)
        assert arrow["score"].to_pylist() == [h.score for h in hits]
        return arrow

    with closing(Collection(tmp_path, 1, vectors=schema)) as db:
        db.apply_point_batch([PointMutation.upsert(i-1, vectors={"v": vector},
                              fields=[PayloadField("keep", "bool", i != 0)]) for i, vector in enumerate(vectors)])
        arrow = verify(db)
        db.flush()
    assert len(arrow) == 3
    with closing(Collection(tmp_path, 1)) as db:
        verify(db)


@pytest.mark.parametrize("kind,metric,vectors", [
    ("sparse", "dot", [[SparseElement(1, 1)], [SparseElement(1, 2)], [SparseElement(2, 1)], [SparseElement(1, -2)]]),
    ("binary", "hamming", [b"\x01", b"\x03", b"\x07", b"\x00"]),
    ("binary", "jaccard", [b"\x01", b"\x03", b"\x07", b"\x00"]),
])
def test_sparse_and_binary_exclude_before_selection(tmp_path, kind, metric, vectors):
    field = VectorField(0, kind="sparse", metric="dot") if kind == "sparse" else VectorField(8, dtype="binary", kind=kind, metric=metric)
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": vector}) for i, vector in enumerate(vectors)])
        expected = [hit for hit in db.search_field("v", vectors[0], 10) if hit.id != 0][:2]
        assert db.search_field_by_id("v", 0, 2) == expected
        assert len(expected) == 2


@pytest.mark.parametrize("mode", ["exact", "approx", "ivf"])
def test_id_exclusion_precedes_topk_across_updates_and_run_shadowing(tmp_path, mode):
    field = VectorField(2, metric="l2", hnsw=CollectionConfig.defaults(2))
    options = dict(ef_search=96, rerank_k=96) if mode == "approx" else dict(ivf=IvfOptions(nlist=4, nprobe=4, iterations=2)) if mode == "ivf" else {}
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i, i % 7]}) for i in range(128)])
        db.flush()
        # Freeze a base and then shadow both the query and some candidates.
        db.apply_point_batch([PointMutation.update(64, vectors={"v": [20.25, 6]}),
                              PointMutation.delete(20), PointMutation.update(21, vectors={"v": [99, 99]})])
        hits = db.search_field_by_id("v", 64, 8, mode=mode, **options)
        expected = [hit for hit in db.search_field("v", [20.25, 6], 128) if hit.id != 64][:8]
        assert hits == expected
        assert len(hits) == 8
        db.search_field_by_id("v", 64, 8, mode=mode, **options)
        if mode == "approx":
            assert db.last_search_stats().effective_ef >= 96
        elif mode == "ivf":
            assert db.last_search_stats().ivf_probed_partitions == 4


def test_lookup_failures_and_resource_controls(tmp_path):
    fields = {"v": VectorField(2), "wrong": VectorField(3), "other_type": VectorField(2, dtype="f16")}
    with closing(Collection(tmp_path, 1, vectors=fields, limits=ResourceLimits(max_candidates=1))) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1, 2], "wrong": [1, 2, 3], "other_type": [1, 2]})])
        for kwargs in (dict(lookup_field="missing"), dict(lookup_field="wrong"), dict(lookup_field="other_type"),
                       dict(lookup_field=""), dict(lookup_field=1), dict(lookup_from="other")):
            with pytest.raises(ValidationError):
                db.search_field_by_id("v", 1, 1, **kwargs)
        for id in (True, 1.0, "1", 2**64):
            with pytest.raises(ValidationError):
                db.search_field_by_id("v", id, 1)
        db.apply_point_batch([PointMutation.upsert(2, vectors={"v": [1, 2]})])
        with pytest.raises(Exception, match="candidate resource limit"):
            db.search_field_by_id("v", 1, 1)
        token = CancellationToken()
        token.cancel()
        with pytest.raises(Exception, match="cancel"):
            db.search_field_by_id("v", 1, 1, cancellation=token)
        with pytest.raises(Exception, match="deadline|timeout"):
            db.search_field_by_id("v", 1, 1, timeout_ns=1)


def test_alternate_field_same_collection_and_closed_external_lookup(tmp_path):
    fields = {"v": VectorField(1), "source": VectorField(1)}
    with closing(Collection(tmp_path / "target", 1, vectors=fields)) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"source": [0]}),
                              PointMutation.upsert(2, vectors={"v": [0]}),
                              PointMutation.upsert(3, vectors={"v": [1]})])
        assert [hit.id for hit in db.search_field_by_id("v", 1, 2, lookup_field="source")] == [2, 3]
        other = Collection(tmp_path / "other", 1, vectors=fields)
        other.close()
        with pytest.raises(Exception, match="closed"):
            db.search_field_by_id("v", 1, 2, lookup_from=other)


def test_missing_deleted_empty_and_self_only_points(tmp_path):
    fields = {"v": VectorField(1), "s": VectorField(0, kind="sparse", metric="dot"),
              "m": VectorField(1, kind="multivector", metric="dot")}
    with closing(Collection(tmp_path, 1, vectors=fields)) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1], "s": [], "m": []})])
        assert db.search_field_by_id("v", 1, 5) == []
        assert db.search_field_by_id("s", 1, 5) == []
        with pytest.raises(ValidationError, match="at least one row"):
            db.search_field_by_id("m", 1, 5)
        db.apply_point_batch([PointMutation.update(1, vectors={"v": None})])
        with pytest.raises(ValidationError, match="no requested vector"):
            db.search_field_by_id("v", 1, 5)
        db.apply_point_batch([PointMutation.delete(1)])
        with pytest.raises(ValidationError, match="point not found"):
            db.search_field_by_id("s", 1, 5)


def test_hnsw_selective_filter_fallback_keeps_exclusion(tmp_path):
    field = VectorField(1, metric="l2", hnsw=CollectionConfig.defaults(1))
    predicate = dict(kind="condition", name="group", operator="le", type="int", value=3)
    with closing(Collection(tmp_path, 1, vectors={"v": field})) as db:
        db.apply_point_batch([PointMutation.upsert(i, vectors={"v": [i]},
                              fields=[PayloadField("group", "int", i)]) for i in range(128)])
        hits = db.search_field_by_id("v", 0, 3, filter=predicate, mode="approx", ef_search=32)
        assert [(hit.id, hit.score) for hit in hits] == [(1, 1.0), (2, 4.0), (3, 9.0)]
        assert db.last_search_stats().storage_name == "field-flat"
        assert db.last_search_stats().fallback_reason
        # Only the excluded source survives the predicate: zero eligible rows.
        assert db.search_field_by_id("v", 0, 3, filter=dict(predicate, value=0), mode="approx", ef_search=32) == []
