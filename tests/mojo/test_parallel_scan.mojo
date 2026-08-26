from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    SearchResult,
)
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_raises, TestSuite


def _reset(path: String) raises:
    ensure_directory(path)
    remove_file_if_exists(path + "/manifest.bin")
    remove_file_if_exists(path + "/manifest.bin.tmp")
    remove_file_if_exists(path + "/wal.bin")
    remove_file_if_exists(path + "/wal.bin.tmp")
    remove_file_if_exists(path + "/sparse.wal")
    remove_file_if_exists(path + "/sparse.wal.tmp")


def _assert_same(
    lhs: List[SearchResult], rhs: List[SearchResult]
) raises:
    assert_equal(len(lhs), len(rhs))
    for index in range(len(lhs)):
        assert_equal(lhs[index].id, rhs[index].id)
        assert_equal(lhs[index].score, rhs[index].score)


def test_parallel_scan_matches_scalar_for_workers_metrics_tails_and_ties() raises:
    var path = String("/tmp/akasha-phase12-parallel-scan")
    _reset(path)
    var collection = PersistentCollection.open(path, 3)
    for id in range(1, 102):
        collection.upsert(
            id,
            [
                Float32(id % 9) + 0.5,
                Float32((id * 5) % 13),
                Float32((id * 7) % 17),
            ],
        )
    collection.upsert(200, [9.0, 9.0, 9.0])
    collection.upsert(199, [9.0, 9.0, 9.0])
    var snapshot = collection.snapshot()
    var query: List[Float32] = [2.5, 3.0, 4.0]

    for workers in range(1, 5):
        _assert_same(
            snapshot.search_dot(query, 12),
            snapshot.search_dot_parallel(query, 12, num_workers=workers),
        )
        _assert_same(
            snapshot.search_l2(query, 12),
            snapshot.search_l2_parallel(query, 12, num_workers=workers),
        )
        _assert_same(
            snapshot.search_cosine(query, 12),
            snapshot.search_cosine_parallel(
                query, 12, num_workers=workers
            ),
        )
    _assert_same(
        snapshot.search_dot(query, 12),
        snapshot.search_dot_parallel(query, 12),
    )
    collection.close()


def test_parallel_filtered_scan_matches_expression_oracle() raises:
    var path = String("/tmp/akasha-phase12-parallel-filter")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    for id in range(1, 42):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField(
                "group",
                PayloadValue.string("keep" if id % 3 == 0 else "drop"),
            )
        )
        collection.upsert_document(
            id, [Float32(id), Float32(id % 5) + 1.0], fields^
        )
    var expression = FilterExpression.condition(
        FilterCondition.equal("group", PayloadValue.string("keep"))
    )
    var snapshot = collection.snapshot()
    _assert_same(
        snapshot.search_dot_where([1.0, 0.0], 7, expression),
        snapshot.search_dot_where_parallel(
            [1.0, 0.0], 7, expression, num_workers=4
        ),
    )
    collection.close()


def test_parallel_scan_validates_worker_count() raises:
    var path = String("/tmp/akasha-phase12-parallel-validation")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    var snapshot = collection.snapshot()
    with assert_raises():
        _ = snapshot.search_dot_parallel([1.0], 1, num_workers=-1)
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
