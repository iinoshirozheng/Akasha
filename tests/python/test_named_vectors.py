from pathlib import Path

import pytest
import numpy as np

from akashadb import (
    Collection,
    LocalDatabase,
    CollectionConfig,
    PayloadField,
    PointMutation,
    SparseElement,
    ValidationError,
    VectorField,
)


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
def test_native_named_vectors_round_trip_search_and_reopen(tmp_path: Path, dtype: str):
    path = tmp_path / dtype
    fields = {"embedding": VectorField(2, dtype=dtype, metric="dot")}
    collection = Collection(path, 2, vectors=fields)
    accepted = collection.apply_point_batch([
        PointMutation.upsert(1, vectors={"embedding": [2, 3]}),
        PointMutation.upsert(2, vectors={"embedding": [4, 5]}),
    ])
    assert accepted.count == 2
    assert accepted.last_sequence == 2
    point = collection.get_point(1)
    assert point.vector is None
    assert point.document_sequence == 0
    assert point.vectors == {"embedding": [2, 3]}
    assert collection.search_field("embedding", [1, 0], 1)[0].id == 2
    assert collection.vector_fields() == fields
    collection.flush()
    collection.close()
    reopened = Collection(path, 2)
    assert reopened.vector_fields() == fields
    assert reopened.get_point(1).vectors == {"embedding": [2, 3]}
    assert reopened.search_field("embedding", [1, 0], 1)[0].score == 4.0
    reopened.close()


def test_combined_mutation_preserve_remove_and_delete_reinsert(tmp_path: Path):
    collection = Collection(tmp_path, 2, vectors={"image": VectorField(1, dtype="f16")})
    collection.apply_point_batch([
        PointMutation.upsert(1, vector=[1, 2], sparse=[SparseElement(3, 4)],
                             vectors={"image": [5]}, fields=[PayloadField("tag", "string", "a")])
    ])
    collection.apply_point_batch([PointMutation.update(1, vectors={"image": [6]})])
    point = collection.get_point(1)
    assert point.sequence == 2
    assert point.document_sequence == 1
    assert point.vector == [1, 2]
    assert point.sparse == [SparseElement(3, 4)]
    assert point.fields == [PayloadField("tag", "string", "a")]
    collection.apply_point_batch([PointMutation.update(1, vectors={"image": None}, sparse=[])])
    point = collection.get_point(1)
    assert point.vectors == {}
    assert point.sparse == []
    collection.apply_point_batch([PointMutation.delete(1), PointMutation.upsert(1, vectors={"image": [7]})])
    point = collection.get_point(1)
    assert point.vector is None
    assert point.sparse is None
    assert point.fields == []
    collection.close()


def test_late_field_validation_never_commits_prefix(tmp_path: Path):
    collection = Collection(tmp_path, 2, vectors={"tiny": VectorField(1, dtype="u8")})
    collection.upsert(1, [1, 2])
    before = (tmp_path / "wal.bin").read_bytes()
    with pytest.raises(ValidationError):
        collection.apply_point_batch([PointMutation.update(1, vector=[8, 9], vectors={"tiny": [256]})])
    assert collection.last_sequence == 1
    assert (tmp_path / "wal.bin").read_bytes() == before
    assert collection.get_point(1).vector == [1, 2]
    with pytest.raises(ValidationError):
        collection.apply_point_batch([PointMutation.update(99, vectors={"tiny": [1]})])
    with pytest.raises(ValidationError):
        collection.search_field("missing", [1], 1)
    collection.close()


def test_packed_binary_and_ragged_maxsim_preserve_shapes(tmp_path: Path):
    fields = {
        "bits": VectorField(9, kind="binary", dtype="binary", metric="hamming"),
        "patches": VectorField(2, kind="multivector", dtype="f16", metric="dot"),
    }
    collection = Collection(tmp_path, 2, vectors=fields)
    collection.apply_point_batch([
        PointMutation.upsert(1, vectors={"bits": b"\x01\x01", "patches": [[2, 1], [-1, 3]]}),
        PointMutation.upsert(2, vectors={"bits": b"\x00\x00", "patches": []}),
    ])
    assert collection.search_field("bits", b"\x01\x01", 2)[1].score == 2.0
    hits = collection.search_field("patches", [[1, 0], [0, 1]], 2)
    assert [(hit.id, hit.score) for hit in hits] == [(1, 5.0)]
    collection.flush()
    collection.close()
    reopened = Collection(tmp_path, 2)
    assert reopened.get_point(1).vectors["bits"] == b"\x01\x01"
    assert reopened.get_point(1).vectors["patches"] == [[2, 1], [-1, 3]]
    assert reopened.get_point(2).vectors["patches"] == []
    reopened.close()


@pytest.mark.parametrize("dtype", ["f32", "f16", "i8", "u8"])
@pytest.mark.parametrize("strided", [False, True])
def test_numpy_native_authority_owns_input(tmp_path: Path, dtype: str, strided: bool):
    array_type = {"f32": "float32", "f16": "float16", "i8": "int8", "u8": "uint8"}[dtype]
    collection = Collection(tmp_path, 2, vectors={
        "dense": VectorField(2, dtype=dtype),
        "matrix": VectorField(2, dtype=dtype, kind="multivector"),
    })
    source = np.arange(8, dtype=array_type).reshape(2, 4)
    matrix = source[:, ::2] if strided else source[:, :2].copy()
    expected = matrix.copy()
    collection.apply_point_batch([PointMutation.upsert(1, vectors={"dense": matrix[0], "matrix": matrix})])
    source[:] = 0
    matrix[:] = 0
    assert collection.get_point(1).vectors == {"dense": expected[0].tolist(), "matrix": expected.tolist()}
    assert collection.search_field("dense", expected[0], 1)[0].score == 0.0
    collection.flush()
    collection.close()
    reopened = Collection(tmp_path, 2)
    assert reopened.get_point(1).vectors["matrix"] == expected.tolist()
    reopened.close()


@pytest.mark.parametrize("dtype,value", [
    ("i8", -129), ("i8", 128), ("i8", 1.5), ("u8", -1), ("u8", 256),
    ("f16", 1e10), ("f32", float("nan")), ("bf16", float("inf")), ("f32", True),
])
def test_invalid_native_component_rejects_entire_batch(tmp_path: Path, dtype: str, value):
    collection = Collection(tmp_path, 1, vectors={"v": VectorField(1, dtype=dtype)})
    before = (tmp_path / "wal.bin").read_bytes()
    with pytest.raises(ValidationError):
        collection.apply_point_batch([
            PointMutation.upsert(1, vectors={"v": [1]}),
            PointMutation.upsert(2, vectors={"v": [value]}),
        ])
    assert collection.last_sequence == 0
    assert collection.get_point(1) is None
    assert (tmp_path / "wal.bin").read_bytes() == before
    collection.close()


def test_named_sparse_filter_and_catalog_identity(tmp_path: Path):
    fields = {"詞": VectorField(0, kind="sparse", metric="dot")}
    database = LocalDatabase(tmp_path)
    collection = database.open("docs", 2, vectors=fields)
    assert database.open("docs", 2, vectors=fields) is collection
    with pytest.raises(ValidationError):
        database.open("docs", 2, vectors={})
    collection.apply_point_batch([
        PointMutation.upsert(1, vectors={"詞": [SparseElement(7, 3)]}, fields=[PayloadField("tag", "string", "keep")]),
        PointMutation.upsert(2, vectors={"詞": [SparseElement(7, 5)]}),
        PointMutation.upsert(3, vectors={"詞": []}),
    ])
    expression = {"kind": "condition", "operator": "eq", "name": "tag", "type": "string", "value": "keep"}
    hits = collection.search_field("詞", [SparseElement(7, 2)], 3, filter=expression)
    assert [(hit.id, hit.score) for hit in hits] == [(1, 6.0)]
    assert collection.get_point(1).vectors == {"詞": [SparseElement(7, 3)]}
    assert collection.get_point(3).vectors == {"詞": []}
    database.close_all()
    with pytest.raises(ValidationError):
        Collection(tmp_path / "docs", 2, vectors={"詞": VectorField(2)})
    reopened = Collection(tmp_path / "docs", 2)
    assert reopened.vector_fields() == fields
    reopened.close()


def test_legacy_migration_and_separate_index_config(tmp_path: Path):
    collection = Collection(tmp_path, 2)
    collection.upsert(1, [1, 2])
    collection.flush()
    collection.close()
    fields = {"half": VectorField(3, dtype="f16", hnsw=CollectionConfig(dimension=3))}
    upgraded = Collection(tmp_path, 2, vectors=fields)
    assert upgraded.get_point(1).vector == [1, 2]
    upgraded.apply_point_batch([PointMutation.update(1, vectors={"half": [3, 4, 5]})])
    assert upgraded.get_point(1).document_sequence == 1
    assert upgraded.vector_fields() == fields
    upgraded.close()
    reopened = Collection(tmp_path, 2)
    assert reopened.get_point(1).vectors == {"half": [3, 4, 5]}
    reopened.close()


@pytest.mark.parametrize("dtype", ["f32", "f16", "bf16", "i8", "u8"])
@pytest.mark.parametrize("metric", ["dot", "l2", "cosine"])
def test_named_hnsw_native_rerank_and_arrow(tmp_path, dtype, metric):
    from akashadb.arrow import search_field_record_batch

    graph_dtype = "f16" if dtype == "u8" else ("i8" if dtype == "i8" and metric == "cosine" else "bf16")
    config = CollectionConfig(5, ann_metric=metric, scalar_kind=graph_dtype,
                              m=4, m0=8, ef_construction=64,
                              default_ef_search=128, max_ef_search=256)
    schema = {"embedding": VectorField(5, dtype=dtype, metric=metric, hnsw=config)}
    collection = Collection(tmp_path, 2, vectors=schema)
    rows = [PointMutation.upsert(-row, vectors={} if row % 7 == 0 else {
        "embedding": [row % 11 + 1, row % 13, row % 17, row % 19, 3]
    }, fields=[PayloadField("group", "int", row % 2)]) for row in range(80)]
    collection.apply_point_batch(rows)
    query = [2, 3, 4, 5, 1]
    filters = [None, {"kind": "condition", "operator": "eq", "name": "group", "type": "int", "value": 1}]
    for expression in filters:
        expected = collection.search_field("embedding", query, 7, filter=expression)
        actual = collection.search_field("embedding", query, 7, filter=expression,
                                         mode="approx", ef_search=128, rerank_k=128)
        assert actual == expected
        assert collection.last_search_stats().storage_name == f"field-hnsw-{graph_dtype}"
        batch = search_field_record_batch(collection, "embedding", query, 7,
                                          filter=expression, mode="approx", ef_search=128)
        assert batch.column("id").to_pylist() == [hit.id for hit in expected]
        assert batch.column("score").to_pylist() == [hit.score for hit in expected]
        assert str(batch.schema.field("score").type) == "double"
    collection.apply_point_batch([PointMutation.delete(-1), PointMutation.update(-2, vectors={"embedding": None}),
                                  PointMutation.upsert(-100, vectors={"embedding": query})])
    expected = collection.search_field("embedding", query, 7)
    assert collection.search_field("embedding", query, 7, mode="approx", ef_search=128) == expected
    collection.flush()
    collection.close()
    reopened = Collection(tmp_path, 2)
    assert reopened.search_field("embedding", query, 7, mode="approx", ef_search=128) == expected
    reopened.close()
    assert batch.num_rows == 7


@pytest.mark.parametrize("options", [
    {"mode": "unknown"}, {"ef_search": 12}, {"rerank_k": 12},
    {"mode": "approx", "ef_search": 0}, {"mode": "approx", "ef_search": True},
    {"mode": "approx", "ef_search": 513}, {"mode": "approx", "rerank_k": 1},
    {"mode": "approx", "rerank_k": -1}, {"mode": "approx", "rerank_k": True},
])
def test_named_hnsw_rejects_invalid_options(tmp_path, options):
    from akashadb.arrow import search_field_record_batch
    collection = Collection(tmp_path, 2, vectors={"embedding": VectorField(2, hnsw=CollectionConfig(2))})
    for search in (collection.search_field, lambda *a, **kw: search_field_record_batch(collection, *a, **kw)):
        with pytest.raises(ValidationError):
            search("embedding", [1, 2], 2, **options)
    collection.close()


@pytest.mark.parametrize("mode", ["exact", "approx", "ivf"])
def test_named_search_controls_and_retry(tmp_path, mode):
    from akashadb import CancellationToken, ResourceLimits
    from akashadb.arrow import search_field_record_batch

    schema = {"embedding": VectorField(2, hnsw=CollectionConfig(2))}
    collection = Collection(tmp_path, 2, vectors=schema, limits=ResourceLimits(max_candidates=2))
    collection.apply_point_batch([PointMutation.upsert(i, vectors={"embedding": [i, 1]}) for i in range(3)])
    for search in (collection.search_field, lambda *a, **kw: search_field_record_batch(collection, *a, **kw)):
        with pytest.raises(ValidationError, match="resource limit"):
            search("embedding", [1, 1], 1, mode=mode)
        token = CancellationToken()
        token.cancel()
        with pytest.raises(ValidationError, match="cancelled"):
            search("embedding", [1, 1], 1, mode=mode, cancellation=token)
        with pytest.raises(ValidationError, match="deadline"):
            search("embedding", [1, 1], 1, mode=mode, timeout_ns=1)
        for timeout in [0, -1, True]:
            with pytest.raises(ValidationError, match="timeout"):
                search("embedding", [1, 1], 1, mode=mode, timeout_ns=timeout)
    collection.close()
    reopened = Collection(tmp_path, 2)
    assert reopened.search_field("embedding", [1, 1], 1, mode=mode)[0].id == 1
    reopened.close()


@pytest.mark.parametrize("approximate", [False, True])
def test_named_field_fusion_matches_rank_oracle_and_arrow(tmp_path, approximate):
    from akashadb import FieldQuery
    from akashadb.arrow import search_fields_record_batch

    config = CollectionConfig(2, ann_metric="dot", default_ef_search=64)
    schema = {"dense": VectorField(2, metric="dot", hnsw=config),
              "terms": VectorField(0, kind="sparse", metric="dot"),
              "binary": VectorField(9, dtype="binary", kind="binary", metric="hamming")}
    collection = Collection(tmp_path, 1, vectors=schema)
    collection.apply_point_batch([
        PointMutation.upsert(-i, vectors={"dense": [i, 1], "terms": [SparseElement(i % 3, i + 1)],
                                           "binary": (i + 1).to_bytes(2, "little")},
                             fields=[PayloadField("group", "int", i % 2)]) for i in range(11)
    ] + [PointMutation.upsert(-99, vectors={"terms": []})])
    queries = [FieldQuery("dense", [1, 1], mode="approx" if approximate else "exact"),
               FieldQuery("terms", [SparseElement(1, 2)]), FieldQuery("binary", b"\x01\x00")]
    expression = {"kind": "condition", "operator": "eq", "name": "group", "type": "int", "value": 1}
    for filter in (None, expression):
        scores = {}
        for query in queries:
            ranking = collection.search_field(query.name, query.vector, 6, mode=query.mode, filter=filter)
            for rank, hit in enumerate(ranking, 1):
                scores[hit.id] = scores.get(hit.id, 0) + 1 / (60 + rank)
        expected = sorted(scores.items(), key=lambda item: (-item[1], item[0]))[:4]
        actual = collection.search_fields(queries, 4, fetch_k=6, filter=filter)
        assert [(hit.id, hit.score) for hit in actual] == expected
        assert collection.last_search_stats().planner_reason == "field_fusion"
        batch = search_fields_record_batch(collection, queries, 4, fetch_k=6, filter=filter)
        assert batch.column("id").to_pylist() == [item[0] for item in expected]
        assert batch.column("score").to_pylist() == [item[1] for item in expected]
    collection.flush()
    collection.close()
    reopened = Collection(tmp_path, 1)
    assert [(hit.id, hit.score) for hit in reopened.search_fields(queries, 4, fetch_k=6, filter=expression)] == expected
    reopened.close()


@pytest.mark.parametrize("options", [{"fetch_k": 1}, {"rank_constant": 0}, {"rank_constant": True}])
def test_named_field_fusion_rejects_invalid_budgets(tmp_path, options):
    from akashadb import FieldQuery
    collection = Collection(tmp_path, 1, vectors={"dense": VectorField(1)})
    with pytest.raises(ValidationError):
        collection.search_fields([FieldQuery("dense", [1])], 2, **options)
    with pytest.raises(ValidationError):
        collection.search_fields([], 2)
    collection.close()
