import akashadb
from akashadb.arrow import results_to_columns, upsert_columns


def test_package_exposes_project_version() -> None:
    assert akashadb.__version__ == "0.1.0"


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
