import akashadb
from akashadb.arrow import results_to_columns, upsert_columns
import pytest


def test_package_exposes_project_version() -> None:
    assert akashadb.__version__ == "0.1.0"


def test_collection_config_round_trip_reopen_and_stats_are_owned_primitives(
    tmp_path,
) -> None:
    path = tmp_path / "configured"
    requested = akashadb.CollectionConfig(
        dimension=2,
        ann_metric="dot",
        scalar_kind="bf16",
        m=8,
        m0=16,
        ef_construction=64,
        default_ef_search=24,
        max_ef_search=96,
        max_level=20,
        rebuild_inactive_percent=30,
        delta_max_points=256,
        level_seed=12345,
    )
    collection = akashadb.Collection(path, 2, config=requested)
    assert collection.collection_config() == requested
    raw = collection._kernel.collection_config()
    resolved = collection.collection_config()
    assert resolved.fingerprint is not None
    expected = requested.to_kernel()
    expected["level_seed"] = requested.level_seed
    assert raw == {**expected, "fingerprint": resolved.fingerprint}
    assert all(
        isinstance(value, (str, int)) and not isinstance(value, (dict, list))
        for value in raw.values()
    )
    raw["m"] = 999
    assert collection._kernel.collection_config()["m"] == 8

    for point_id in range(64):
        collection.upsert(point_id, [float(point_id + 1), 1.0])
    exact = collection.search(
        akashadb.SearchRequest("l2", 3, vector=[4.0, 1.0])
    )
    approximate = collection.search(
        akashadb.SearchRequest(
            "l2", 3, vector=[4.0, 1.0], mode="approx", ef_search=19
        )
    )
    assert approximate == exact
    stats = collection.last_search_stats()
    assert stats.planner_reason == stats.fallback_reason == "metric_mismatch"
    assert stats.metric_name == "l2"
    assert stats.scalar_name == "f32"
    assert stats.requested_ef == 19
    assert stats.effective_ef == 19
    raw_stats = collection._kernel.last_search_stats()
    assert raw_stats["visited"] == (
        raw_stats["upper_visited"] + raw_stats["base_visited"]
    )
    assert all(
        isinstance(value, (str, int)) and not isinstance(value, (dict, list))
        for value in raw_stats.values()
    )
    raw_stats["planner_reason"] = "mutated"
    assert collection._kernel.last_search_stats()["planner_reason"] == (
        "metric_mismatch"
    )
    collection.close()

    reopened = akashadb.Collection(path, 2, config=requested)
    assert reopened.collection_config() == requested
    reopened.close()
    with pytest.raises(akashadb.ValidationError, match="ann_metric"):
        akashadb.Collection(path, 2)


def test_legacy_dimension_only_open_and_local_database_config_checks(tmp_path) -> None:
    legacy = akashadb.Collection(tmp_path / "legacy", 3)
    assert legacy.collection_config() == akashadb.CollectionConfig.defaults(3)
    legacy.close()

    database = akashadb.LocalDatabase(tmp_path / "database")
    config = akashadb.CollectionConfig.defaults(2, ann_metric="cosine")
    opened = database.open("named", 2, config=config)
    assert opened.collection_config() == config
    assert database.open("named", 2, config=config) is opened
    with pytest.raises(akashadb.ValidationError, match="configuration mismatch"):
        database.open("named", 2)
    database.close_all()


def test_python_collection_config_rejects_invalid_shape() -> None:
    with pytest.raises(ValueError, match="ann_metric"):
        akashadb.CollectionConfig.defaults(2, ann_metric="angular")
    with pytest.raises(ValueError, match="dimension"):
        akashadb.CollectionConfig.defaults(0)


def test_collection_accepts_partial_ann_config_dict(tmp_path) -> None:
    collection = akashadb.Collection(
        tmp_path / "partial-config",
        2,
        config={"ann_metric": "dot", "m": 8, "m0": 16, "ef_construction": 64},
    )
    assert collection.collection_config().ann_metric == "dot"
    assert collection.collection_config().m == 8
    collection.close()


@pytest.mark.parametrize("seed", [0, 0xFFFF_FFFF_FFFF_FFFF])
def test_collection_config_preserves_unsigned_seed_extremes(tmp_path, seed) -> None:
    collection = akashadb.Collection(
        tmp_path / f"seed-{seed}", 2, config={"level_seed": seed}
    )
    assert collection.collection_config().level_seed == seed
    collection.close()


def test_empty_collection_stats_are_owned_zero_primitives(tmp_path) -> None:
    collection = akashadb.Collection(tmp_path / "empty-stats", 2)
    stats = collection._kernel.last_search_stats()
    assert stats["planner_reason"] == ""
    assert stats["fallback_reason"] == ""
    assert all(
        stats[name] == 0
        for name in (
            "requested_ef",
            "effective_ef",
            "widening_rounds",
            "upper_visited",
            "base_visited",
            "visited",
            "distance_evaluations",
            "retained_candidates",
            "reranked_candidates",
            "filtered_rejections",
            "inactive_rejections",
            "base_candidates",
            "delta_candidates",
        )
    )
    stats["visited"] = 99
    assert collection._kernel.last_search_stats()["visited"] == 0
    collection.close()


def test_compiled_kernel_rejects_unknown_config_before_creating_state(tmp_path) -> None:
    path = tmp_path / "unknown-kernel-config"
    with pytest.raises(Exception, match="unknown collection config option"):
        akashadb._kernel.Collection(str(path), 2, {"unsupported": 1})
    assert not path.exists()


def test_compiled_kernel_config_none_and_exact_types(tmp_path) -> None:
    from akashadb.database import _kernel_module

    kernel = _kernel_module()
    explicit_none = kernel.Collection(
        str(tmp_path / "explicit-none"), 2, None
    )
    assert explicit_none.collection_config()["ann_metric"] == "l2"
    explicit_none.close()

    keyword = kernel.Collection(
        str(tmp_path / "keyword-config"),
        2,
        config={"ann_metric": "dot"},
    )
    assert keyword.collection_config()["ann_metric"] == "dot"
    keyword.close()

    unsupported_path = tmp_path / "unsupported-keyword"
    with pytest.raises(Exception, match="keyword"):
        kernel.Collection(str(unsupported_path), 2, unsupported=True)
    assert not unsupported_path.exists()

    duplicate_path = tmp_path / "duplicate-config"
    with pytest.raises(Exception, match="config"):
        kernel.Collection(
            str(duplicate_path),
            2,
            {"ann_metric": "dot"},
            config={"ann_metric": "cosine"},
        )
    assert not duplicate_path.exists()

    invalid_values = (
        {"default_ef_search": True},
        {"level_seed": False},
        {"m": 8.0},
        {"m0": "16"},
        {"ann_metric": 7},
        {"scalar_kind": b"f32"},
    )
    for index, config in enumerate(invalid_values):
        path = tmp_path / f"bad-type-{index}"
        with pytest.raises(Exception, match="must be"):
            kernel.Collection(str(path), 2, config)
        assert not path.exists()

    with pytest.raises(Exception, match="dimension must be"):
        kernel.Collection(str(tmp_path / "bool-dimension"), True)


def test_compiled_kernel_supports_document_dense_sparse_hybrid_and_reopen(
    tmp_path,
) -> None:
    path = tmp_path / "vectors"
    collection = akashadb.Collection(path, 2)
    collection.upsert(
        1,
        [1.0, 0.0],
        [akashadb.PayloadField("kind", "string", "chunk")],
    )
    collection.upsert(2, [0.5, 0.5])
    collection.upsert_sparse(1, [akashadb.SparseElement(7, 2.0)])
    collection.upsert_sparse(2, [akashadb.SparseElement(7, 1.0)])

    exact = collection.search(
        akashadb.SearchRequest("dot", 2, vector=[1.0, 0.0])
    )
    sparse = collection.search(
        akashadb.SearchRequest(
            "dot", 2, sparse=[akashadb.SparseElement(7, 1.0)], mode="sparse"
        )
    )
    hybrid = collection.search(
        akashadb.SearchRequest(
            "dot",
            2,
            vector=[1.0, 0.0],
            sparse=[akashadb.SparseElement(7, 1.0)],
            mode="hybrid",
            fetch_k=2,
        )
    )
    filtered = collection.search(
        akashadb.SearchRequest(
            "dot",
            2,
            vector=[1.0, 0.0],
            filter={
                "kind": "condition",
                "name": "kind",
                "operator": "eq",
                "type": "string",
                "value": "chunk",
            },
        )
    )
    assert [item.id for item in exact] == [1, 2]
    assert [item.id for item in sparse] == [1, 2]
    assert hybrid[0].id == 1
    assert [item.id for item in filtered] == [1]
    assert collection.get(1).fields[0].value == "chunk"
    collection.flush()
    collection.close()

    reopened = akashadb.Collection(path, 2)
    assert reopened.get(1).vector == [1.0, 0.0]
    assert reopened.last_sequence == 4
    reopened.close()


def test_copying_arrow_compatible_columns(tmp_path) -> None:
    collection = akashadb.Collection(tmp_path / "arrow", 2)
    count = upsert_columns(
        collection,
        {"id": [3, 4], "vector": [[1.0, 0.0], [0.0, 1.0]]},
    )
    results = collection.search(
        akashadb.SearchRequest("dot", 2, vector=[1.0, 0.0])
    )
    columns = results_to_columns(results)
    assert count == 2
    assert columns["id"] == [3, 4]
    assert columns["score"] == [1.0, 0.0]
    collection.close()


def test_compiled_kernel_applies_typed_atomic_batch(tmp_path) -> None:
    path = tmp_path / "batch"
    collection = akashadb.Collection(path, 2)
    collection.upsert(9, [9.0, 0.0])
    committed = collection.apply_batch(
        [
            akashadb.BatchMutation.upsert(1, [1.0, 0.0]),
            akashadb.BatchMutation.upsert(
                2,
                [0.0, 2.0],
                [akashadb.PayloadField("chunk", "string", "python batch")],
            ),
            akashadb.BatchMutation.delete(9),
        ]
    )

    assert committed == akashadb.BatchWriteResult(2, 4, 3)
    assert collection.get(1).vector == [1.0, 0.0]
    assert collection.get(2).fields[0].value == "python batch"
    assert collection.get(9) is None
    collection.close()

    reopened = akashadb.Collection(path, 2)
    assert reopened.last_sequence == 4
    assert reopened.get(2).fields[0].value == "python batch"
    reopened.close()


def test_compiled_kernel_parallel_batch_query_matches_single_queries(tmp_path) -> None:
    collection = akashadb.Collection(tmp_path / "batch-query", 2)
    for point_id in range(80):
        collection.upsert(
            point_id,
            [float(point_id % 9 - 4), float(point_id % 5 - 2) + 0.25],
        )
    vectors = [[1.0, 0.0], [0.0, 1.0], [-1.0, 0.5], [0.5, -1.0]]

    batched = collection.search_batch("dot", vectors, 6, num_workers=4)

    assert len(batched) == len(vectors)
    for index, vector in enumerate(vectors):
        oracle = collection.search(
            akashadb.SearchRequest("dot", 6, vector=vector)
        )
        assert batched[index] == oracle
    collection.close()


def test_compiled_kernel_filtered_batch_query_matches_single_queries(tmp_path) -> None:
    collection = akashadb.Collection(tmp_path / "batch-query-filtered", 1)
    for point_id in range(20):
        collection.upsert(
            point_id,
            [float(point_id + 1)],
            [
                akashadb.PayloadField(
                    "group", "string", "even" if point_id % 2 == 0 else "odd"
                )
            ],
        )
    vectors = [[1.0], [-1.0]]
    filters = [
        {
            "kind": "condition",
            "name": "group",
            "operator": "eq",
            "type": "string",
            "value": group,
        }
        for group in ("even", "odd")
    ]

    batched = collection.search_batch(
        "dot", vectors, 5, num_workers=2, filters=filters
    )

    for index, vector in enumerate(vectors):
        oracle = collection.search(
            akashadb.SearchRequest(
                "dot", 5, vector=vector, filter=filters[index]
            )
        )
        assert batched[index] == oracle
    collection.close()


def test_compiled_kernel_rebuilds_nested_metadata_index_on_reopen(tmp_path) -> None:
    path = tmp_path / "indexed"
    collection = akashadb.Collection(path, 1)
    collection.upsert(
        1,
        [1.0],
        [
            akashadb.PayloadField("category", "string", "keep"),
            akashadb.PayloadField("page", "int", 1),
        ],
    )
    collection.upsert(
        2,
        [2.0],
        [
            akashadb.PayloadField("category", "string", "drop"),
            akashadb.PayloadField("page", "int", 8),
        ],
    )
    collection.upsert(
        3,
        [3.0],
        [
            akashadb.PayloadField("category", "string", "drop"),
            akashadb.PayloadField("page", "int", 1),
        ],
    )
    collection.flush()
    collection.close()

    reopened = akashadb.Collection(path, 1)
    nested = {
        "kind": "any",
        "children": [
            {
                "kind": "condition",
                "name": "category",
                "operator": "eq",
                "type": "string",
                "value": "keep",
            },
            {
                "kind": "condition",
                "name": "page",
                "operator": "ge",
                "type": "int",
                "value": 5,
            },
        ],
    }
    results = reopened.search(
        akashadb.SearchRequest("dot", 3, vector=[1.0], filter=nested)
    )
    assert [item.id for item in results] == [2, 1]
    reopened.close()
