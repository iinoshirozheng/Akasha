from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
)
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_raises, TestSuite


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/sparse.wal")
    remove_file_if_exists(directory + "/sparse.wal.tmp")


def _queries() -> List[List[Float32]]:
    var queries = List[List[Float32]]()
    queries.append([1.0, 0.0])
    queries.append([0.0, 1.0])
    queries.append([1.0, 1.0])
    queries.append([-1.0, 0.5])
    queries.append([0.25, -1.0])
    queries.append([2.0, 1.0])
    queries.append([-1.0, -1.0])
    queries.append([0.5, 0.5])
    return queries^


def test_parallel_batch_results_equal_single_query_oracle_for_all_metrics() raises:
    var path = String("/tmp/akasha-phase11-batch-query")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    for point_id in range(96):
        collection.upsert(
            point_id,
            [
                Float32(point_id % 11 - 5),
                Float32(point_id % 7 - 3) + 0.25,
            ],
        )
    var snapshot = collection.snapshot()
    var queries = _queries()

    var dot = snapshot.search_dot_batch(queries, 7, num_workers=4)
    var l2 = snapshot.search_l2_batch(queries, 7, num_workers=4)
    var cosine = snapshot.search_cosine_batch(queries, 7, num_workers=4)

    assert_equal(len(dot), len(queries))
    for index in range(len(queries)):
        var dot_oracle = snapshot.search_dot(queries[index], 7)
        var l2_oracle = snapshot.search_l2(queries[index], 7)
        var cosine_oracle = snapshot.search_cosine(queries[index], 7)
        for result_index in range(7):
            assert_equal(
                dot[index][result_index].id, dot_oracle[result_index].id
            )
            assert_equal(
                dot[index][result_index].score, dot_oracle[result_index].score
            )
            assert_equal(l2[index][result_index].id, l2_oracle[result_index].id)
            assert_equal(
                l2[index][result_index].score, l2_oracle[result_index].score
            )
            assert_equal(
                cosine[index][result_index].id,
                cosine_oracle[result_index].id,
            )
            assert_equal(
                cosine[index][result_index].score,
                cosine_oracle[result_index].score,
            )
    snapshot.close()
    collection.close()


def test_batch_query_preserves_ties_input_order_and_validation() raises:
    var path = String("/tmp/akasha-phase11-batch-query-ties")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(9, [1.0])
    collection.upsert(2, [1.0])
    collection.upsert(5, [-1.0])
    var snapshot = collection.snapshot()
    var queries = List[List[Float32]]()
    queries.append([1.0])
    queries.append([-1.0])

    var results = snapshot.search_dot_batch(queries, 3, num_workers=2)

    assert_equal(results[0][0].id, 2)
    assert_equal(results[0][1].id, 9)
    assert_equal(results[1][0].id, 5)
    var invalid = List[List[Float32]]()
    invalid.append([1.0])
    invalid.append([1.0, 2.0])
    with assert_raises():
        _ = snapshot.search_dot_batch(invalid, 2, num_workers=2)
    with assert_raises():
        _ = snapshot.search_dot_batch(queries, 2, num_workers=-1)
    snapshot.close()
    collection.close()


def test_empty_batch_query_returns_empty_results() raises:
    var path = String("/tmp/akasha-phase11-batch-query-empty")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var snapshot = collection.snapshot()
    var queries = List[List[Float32]]()
    assert_equal(len(snapshot.search_dot_batch(queries, 1)), 0)
    snapshot.close()
    collection.close()


def test_parallel_filtered_batch_equals_per_query_expression_oracle() raises:
    var path = String("/tmp/akasha-phase11-batch-query-filtered")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for point_id in range(12):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField(
                "group",
                PayloadValue.string("even" if point_id % 2 == 0 else "odd"),
            )
        )
        collection.upsert_document(point_id, [Float32(point_id + 1)], fields^)
    var snapshot = collection.snapshot()
    var queries = List[List[Float32]]()
    queries.append([1.0])
    queries.append([-1.0])
    var expressions = List[FilterExpression]()
    expressions.append(
        FilterExpression.condition(
            FilterCondition.equal("group", PayloadValue.string("even"))
        )
    )
    expressions.append(
        FilterExpression.condition(
            FilterCondition.equal("group", PayloadValue.string("odd"))
        )
    )

    var results = snapshot.search_dot_where_batch(
        queries, expressions, 4, num_workers=2
    )
    var collection_dot = collection.search_dot_where_batch(
        queries, expressions, 4, num_workers=2
    )
    var collection_l2 = collection.search_l2_where_batch(
        queries, expressions, 4, num_workers=2
    )
    var collection_cosine = collection.search_cosine_where_batch(
        queries, expressions, 4, num_workers=2
    )

    for index in range(len(queries)):
        var oracle = snapshot.search_dot_where(
            queries[index], 4, expressions[index]
        )
        var l2_oracle = snapshot.search_l2_where(
            queries[index], 4, expressions[index]
        )
        var cosine_oracle = snapshot.search_cosine_where(
            queries[index], 4, expressions[index]
        )
        for result_index in range(4):
            assert_equal(
                results[index][result_index].id, oracle[result_index].id
            )
            assert_equal(
                results[index][result_index].score,
                oracle[result_index].score,
            )
            assert_equal(
                collection_dot[index][result_index].id,
                oracle[result_index].id,
            )
            assert_equal(
                collection_l2[index][result_index].id,
                l2_oracle[result_index].id,
            )
            assert_equal(
                collection_cosine[index][result_index].id,
                cosine_oracle[result_index].id,
            )
    var missing = List[FilterExpression]()
    with assert_raises():
        _ = snapshot.search_dot_where_batch(queries, missing, 4, num_workers=2)
    snapshot.close()
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
