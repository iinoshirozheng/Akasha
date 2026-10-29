"""End-to-end native recommendation queries versus unedited Qdrant Rust."""
from contextlib import closing
import json
from pathlib import Path
import struct

import pytest

from akashadb import (CancellationToken, Collection, PayloadField, PointMutation,
                     ResourceLimits, SparseElement, ValidationError, VectorField)
from akashadb.arrow import recommend_field_record_batch

FIXTURE = json.loads((Path(__file__).parents[1] / "fixtures/qdrant-recommendation/recommendation.json").read_text())


def f32(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def vector(raw, kind):
    return [SparseElement(*term) for term in raw] if kind == "sparse" else raw


@pytest.mark.parametrize("sample", FIXTURE["cases"])
def test_recommendations_match_rust_pipeline(tmp_path, sample):
    schema = VectorField(sample["dimension"], kind=sample["kind"], metric=sample["metric"])
    source_schema = VectorField(sample["dimension"], kind=sample["kind"], metric=sample["source_metric"])
    with closing(Collection(tmp_path, 1, vectors={"v": schema, "source": source_schema})) as db:
        db.apply_point_batch([PointMutation.upsert(i+1, vectors={"v": vector(raw, sample["kind"])})
                              for i, raw in enumerate(sample["candidates"])])
        positives = [vector(raw, sample["kind"]) for raw in sample["positive"]]
        negatives = [vector(raw, sample["kind"]) for raw in sample["negative"]]
        for base, values, ids in ((100, positives, sample["positive_ids"]), (200, negatives, sample["negative_ids"])):
            for index in ids:
                db.apply_point_batch([PointMutation.upsert(base+index, vectors={"source": values[index]})])
                values[index] = base+index
        kwargs = dict(positive=positives, negative=negatives, lookup_field="source",
                      strategy=sample["strategy"], k=10)
        if "error" in sample:
            with pytest.raises(ValidationError, match="positive|examples"):
                db.recommend_field("v", **kwargs)
            return
        hits = db.recommend_field("v", **kwargs)
        assert [hit.id for hit in hits] == [row[0] for row in sample["expected"]]
        # Portable scalar Rust/LLVM may differ by a few ULPs in normalization.
        assert [hit.score for hit in hits] == pytest.approx([f32(row[1]) for row in sample["expected"]], abs=2e-6, rel=2e-6)
        assert db.last_search_stats().backend_name == "qdrant-recommendation-f32"
        arrow = recommend_field_record_batch(db, "v", **kwargs)
        assert arrow.to_pydict() == {"id": [hit.id for hit in hits], "score": [hit.score for hit in hits]}


@pytest.mark.parametrize("strategy", ["average_vector", "best_score", "sum_scores"])
@pytest.mark.parametrize("external", [False, True])
def test_mixed_ids_lookup_exclusion_filter_reopen(tmp_path, strategy, external):
    schema = {"v": VectorField(1, metric="dot"), "other": VectorField(1, metric="dot", dtype="f16")}
    predicate = dict(kind="condition", name="keep", operator="eq", type="bool", value=True)
    with closing(Collection(tmp_path / "source", 1, vectors=schema)) as source:
        source.apply_point_batch([PointMutation.upsert(1, vectors={"other": [2]})])
        with closing(Collection(tmp_path / "target", 1, vectors=schema)) as target:
            target.apply_point_batch([
                PointMutation.upsert(1, vectors={"v": [9], "other": [2]}, fields=[PayloadField("keep", "bool", True)]),
                PointMutation.upsert(2, vectors={"v": [3]}, fields=[PayloadField("keep", "bool", True)]),
                PointMutation.upsert(3, vectors={"v": [-1]}, fields=[PayloadField("keep", "bool", False)]),
            ])
            target.flush()
        with closing(Collection(tmp_path / "target", 1)) as target:
            lookup = source if external else target
            hits = target.recommend_field("v", [1, [1]], [[-1]], 2, strategy=strategy,
                                          lookup_from=lookup, lookup_field="other", filter=predicate)
            assert [h.id for h in hits] == ([1, 2] if external else [2])
            if strategy == "average_vector":
                assert [h.score for h in hits] == ([36, 12] if external else [12])
            elif strategy == "sum_scores":
                assert [h.score for h in hits] == ([36, 12] if external else [12])
            target.apply_point_batch([PointMutation.update(2, vectors={"v": [-3]})])
            updated = target.recommend_field("v", [1], k=10, lookup_from=lookup, lookup_field="other", strategy=strategy)
            assert 1 not in [h.id for h in updated] if not external else 1 in [h.id for h in updated]


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
@pytest.mark.parametrize("kind", ["dense", "multivector"])
@pytest.mark.parametrize("strategy", ["average_vector", "best_score", "sum_scores"])
def test_datatype_conversion_is_query_preprocess_then_native_cast(tmp_path, dtype, kind, strategy):
    # Fractions must reach the transform before integer truncation. Integer
    # ingestion itself remains strict; only recommendation queries use casts.
    wrap = (lambda value: [value]) if kind == "multivector" else (lambda value: value)
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(2, dtype=dtype, kind=kind, metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": wrap([1, 2])}),
                              PointMutation.upsert(2, vectors={"v": wrap([2, 1])})])
        hits = db.recommend_field("v", [wrap([1.5, 0.5])], strategy=strategy)
        assert [h.id for h in hits] == [2, 1]
        expected = 2.0 if dtype in ("i8", "u8") else 3.5
        if strategy == "best_score":
            expected = 0.5 * (expected / (1 + expected) + 1)
        assert hits[0].score == pytest.approx(expected)


@pytest.mark.parametrize("strategy", ["average_vector", "best_score", "sum_scores"])
def test_l2_custom_scores_do_not_postprocess_distance(tmp_path, strategy):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(1, metric="l2")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [0]}), PointMutation.upsert(2, vectors={"v": [3]})])
        hits = db.recommend_field("v", [[1]], strategy=strategy)
        assert [h.id for h in hits] == [1, 2]
        expected = {"average_vector": [1, 2], "best_score": [0.25, 0.1], "sum_scores": [-1, -4]}[strategy]
        assert [h.score for h in hits] == pytest.approx(expected)


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
@pytest.mark.parametrize("kind", ["dense", "multivector"])
def test_cosine_zero_vectors_and_dtype_preprocessing(tmp_path, dtype, kind):
    wrap = (lambda value: [value]) if kind == "multivector" else (lambda value: value)
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(2, dtype=dtype, kind=kind, metric="cosine")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": wrap([3, 4])}),
                              PointMutation.upsert(2, vectors={"v": wrap([0, 5])}),
                              PointMutation.upsert(3, vectors={"v": wrap([0, 0])})])
        hits = db.recommend_field("v", [wrap([3, 4])], strategy="sum_scores")
        assert [h.id for h in hits] == [1, 2, 3]
        assert hits[2].score == 0
        if dtype in ("i8", "u8", "f32"):
            assert [h.score for h in hits] == pytest.approx([1, 0.8, 0])
        else:
            # Typed normalization rounds to the field scalar before F32 dot.
            assert hits[0].score == pytest.approx(1, abs=0.01)
        assert [h.score for h in db.recommend_field("v", [wrap([0, 0])], strategy="sum_scores")] == [0, 0, 0]


def test_u8_query_cast_clamps_and_truncates_after_average(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(2, dtype="u8", metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1, 2]})])
        assert db.recommend_field("v", [[-20, 300.75]], strategy="sum_scores")[0].score == 510
        # average [0.25, 1.25] and [1.75, 2.75] = [1, 2], then convert.
        assert db.recommend_field("v", [[0.25, 1.25], [1.75, 2.75]])[0].score == 5
        # Duplicated examples each contribute to sum_scores.
        before = db.metrics().queries
        assert db.recommend_field("v", [[1, 2], [1, 2]], strategy="sum_scores")[0].score == 10
        assert db.metrics().queries == before + 1


def test_sparse_custom_scores_include_nonoverlap_and_average_excludes_zero(tmp_path):
    with closing(Collection(tmp_path, 1, vectors={"v": VectorField(0, kind="sparse", metric="dot")})) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [SparseElement(1, 1)]}),
                              PointMutation.upsert(2, vectors={"v": [SparseElement(2, 1)]}),
                              PointMutation.upsert(3, vectors={"v": []})])
        assert [h.id for h in db.recommend_field("v", [[SparseElement(1, 1)]])] == [1]
        assert [(h.id, h.score) for h in db.recommend_field("v", [[SparseElement(1, 1)]], strategy="sum_scores")] == [(1, 1), (2, 0), (3, 0)]
        assert [h.id for h in db.recommend_field("v", [], [[SparseElement(1, 1)]], strategy="best_score")] == [2, 3, 1]


def test_errors_controls_and_owned_arrow(tmp_path):
    schema = {"v": VectorField(1, metric="dot"), "binary": VectorField(8, kind="binary", dtype="binary", metric="hamming")}
    with closing(Collection(tmp_path, 1, vectors=schema, limits=ResourceLimits(max_query_batch=2, max_candidates=2))) as db:
        db.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1]}), PointMutation.upsert(2, vectors={"v": [2]})])
        for positive, kwargs in [([], {}), ([99], {}), ([True], {}), ([[1], [1], [1]], {}),
                                 ([[1]], dict(strategy="other")), ([[1]], dict(mode="approx")),
                                 ([[1]], dict(k=0)), ([[1]], dict(lookup_field="")),
                                 ([1], dict(lookup_field="missing")), ([[1]], dict(timeout_ns=-1)),
                                 ([[1, 2]], {}), ([[float("nan")]], {})]:
            with pytest.raises(ValidationError):
                db.recommend_field("v", positive, **kwargs)
        with pytest.raises(ValidationError, match="binary|schema"):
            db.recommend_field("binary", [b"\x01"])
        token = CancellationToken()
        token.cancel()
        with pytest.raises(Exception, match="cancel"):
            db.recommend_field("v", [[1]], cancellation=token)
        with pytest.raises(Exception, match="deadline"):
            db.recommend_field("v", [[1]], timeout_ns=1)
        arrow = recommend_field_record_batch(db, "v", [[1]], strategy="sum_scores")
        db.apply_point_batch([PointMutation.upsert(3, vectors={"v": [3]})])
        with pytest.raises(ValidationError, match="resource"):
            db.recommend_field("v", [[1]])
    assert arrow.to_pydict() == {"id": [2, 1], "score": [2.0, 1.0]}


@pytest.mark.parametrize("close_source", [False, True])
def test_native_conversion_reentry_closes_source_or_target(tmp_path, close_source):
    schema = {"v": VectorField(1, metric="dot")}
    target = Collection(tmp_path / "target", 1, vectors=schema)
    source = Collection(tmp_path / "source", 1, vectors=schema)
    source.apply_point_batch([PointMutation.upsert(1, vectors={"v": [1]})])

    class ClosingOptions(dict):
        def __getitem__(self, key):
            if key == "lookup_from":
                (source if close_source else target).close()
            return super().__getitem__(key)

    options = ClosingOptions(strategy="sum_scores", mode="exact", max_examples=10, cancelled=False,
                             max_candidates=10, deadline_ns=0, filter=None, lookup_from=source._kernel, lookup_field=None)
    try:
        with pytest.raises(Exception, match="closed"):
            target._kernel.recommend_field("v", [1], [], 1, options)
    finally:
        source.close()
        target.close()
