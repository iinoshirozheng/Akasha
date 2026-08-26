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
