from akasha import PersistentCollection
from akasha.index.artifact_state import ARTIFACT_FAILED, ARTIFACT_READY
from akasha.index.flat import SearchResult
from akasha.index.quantization import PqCodebook, PqIndex
from akasha.query.control import CancellationToken, QueryControl
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from max.algorithm import parallelize
from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from std.time import perf_counter_ns


def _training_vectors() -> List[List[Float32]]:
    var vectors = List[List[Float32]]()
    for row in range(16):
        vectors.append(
            [
                Float32(row % 4) + 0.25,
                Float32((row * 3) % 7),
                Float32((row * 5) % 11),
                Float32(row) / 3.0,
            ]
        )
    return vectors^


def _reset(path: String) raises:
    ensure_directory(path)
    remove_file_if_exists(path + "/manifest.bin")
    remove_file_if_exists(path + "/manifest.bin.tmp")
    remove_file_if_exists(path + "/wal.bin")
    remove_file_if_exists(path + "/wal.bin.tmp")
    remove_file_if_exists(path + "/sparse.wal")
    remove_file_if_exists(path + "/sparse.wal.tmp")


def test_pq_training_and_codes_are_deterministic() raises:
    var vectors = _training_vectors()
    var lhs = PqCodebook.train(vectors, 2, 4, iterations=6)
    var rhs = PqCodebook.train(vectors, 2, 4, iterations=6)
    assert_equal(lhs.version(), UInt32(1))
    assert_equal(lhs.dimension(), 4)
    assert_equal(lhs.subquantizer_count(), 2)
    assert_equal(lhs.centroid_count(), 4)
    var lhs_code = lhs.encode(vectors[7])
    var rhs_code = rhs.encode(vectors[7])
    assert_equal(len(lhs_code), 2)
    assert_equal(lhs_code[0], rhs_code[0])
    assert_equal(lhs_code[1], rhs_code[1])
    assert_true(Int(lhs_code[0]) < 4)


def test_pq_index_searches_all_metrics() raises:
    var vectors = _training_vectors()
    var ids = List[Int](capacity=len(vectors))
    for index in range(len(vectors)):
        ids.append(index + 1)
    var index = PqIndex.build(ids, vectors, 2, 8, iterations=8)
    var query = vectors[9].copy()
    assert_equal(index.search_l2(query, 1)[0].id, 10)
    assert_true(len(index.search_dot(query, 3)) == 3)
    assert_true(len(index.search_cosine(query, 3)) == 3)
    assert_equal(index.encoded_bytes(), len(vectors) * 2)
    assert_true(index.estimated_bytes() > index.encoded_bytes())


def test_pq_snapshot_rerank_matches_exact_oracle() raises:
    var path = String("/tmp/akasha-phase12-pq-rerank")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    var vectors = _training_vectors()
    for index in range(len(vectors)):
        collection.upsert(index + 1, vectors[index].copy())
    var snapshot = collection.snapshot()
    var query: List[Float32] = [2.2, 3.1, 4.3, 1.7]
    var exact_l2 = snapshot.search_l2(query, 4)
    var exact_dot = snapshot.search_dot(query, 4)
    var exact_cosine = snapshot.search_cosine(query, 4)
    var pq_l2 = snapshot.search_pq_l2(
        query,
        4,
        subquantizers=2,
        centroids=8,
        rerank_k=16,
    )
    var pq_dot = snapshot.search_pq_dot(
        query,
        4,
        subquantizers=2,
        centroids=8,
        rerank_k=16,
    )
    var pq_cosine = snapshot.search_pq_cosine(
        query,
        4,
        subquantizers=2,
        centroids=8,
        rerank_k=16,
    )
    for index in range(4):
        assert_equal(pq_l2[index].id, exact_l2[index].id)
        assert_equal(pq_l2[index].score, exact_l2[index].score)
        assert_equal(pq_dot[index].id, exact_dot[index].id)
        assert_equal(pq_dot[index].score, exact_dot[index].score)
        assert_equal(pq_cosine[index].id, exact_cosine[index].id)
        assert_equal(pq_cosine[index].score, exact_cosine[index].score)
    collection.close()


def test_pq_rejects_malformed_configuration() raises:
    var vectors = _training_vectors()
    with assert_raises():
        _ = PqCodebook.train(vectors, 3, 4)
    with assert_raises():
        _ = PqCodebook.train(vectors, 2, 0)
    with assert_raises():
        _ = PqCodebook.train(vectors, 2, 257)
    with assert_raises():
        _ = PqCodebook.train(vectors, 2, 4, iterations=0)


def _same(expected: List[SearchResult], actual: List[SearchResult]) raises:
    assert_equal(len(actual), len(expected))
    for rank in range(len(expected)):
        assert_equal(actual[rank].id, expected[rank].id)
        assert_equal(actual[rank].score, expected[rank].score)


def _seed(mut collection: PersistentCollection) raises:
    var vectors = _training_vectors()
    for row in range(len(vectors)):
        collection.upsert(row + 1, vectors[row].copy())


def test_pq_cache_keys_all_training_parameters_and_reuses_across_metrics() raises:
    var path = String("/tmp/akasha-55-pq-cache-keys")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var snapshot = collection.snapshot()
    var sibling = collection.snapshot()
    var root = snapshot._acquire()
    var vectors = _training_vectors()
    var ids = List[Int]()
    for row in range(len(vectors)):
        ids.append(row + 1)
    var query: List[Float32] = [2.2, 3.1, 4.3, 1.7]
    var configs: List[Tuple[Int, Int, Int]] = [
        (2, 4, 6),
        (1, 4, 6),
        (2, 8, 6),
        (2, 4, 7),
    ]
    for config in configs:
        var oracle = PqIndex.build(
            ids, vectors, config[0], config[1], iterations=config[2]
        )
        for _ in range(3):
            _same(
                oracle.search_dot(query, 3),
                snapshot.search_pq_dot(
                    query,
                    3,
                    subquantizers=config[0],
                    centroids=config[1],
                    iterations=config[2],
                ),
            )
            _same(
                oracle.search_l2(query, 5),
                sibling.search_pq_l2(
                    query,
                    5,
                    subquantizers=config[0],
                    centroids=config[1],
                    iterations=config[2],
                ),
            )
            _same(
                oracle.search_cosine(query, 4),
                snapshot.search_pq_cosine(
                    query,
                    4,
                    subquantizers=config[0],
                    centroids=config[1],
                    iterations=config[2],
                ),
            )
            _same(
                snapshot.search_l2(query, 4),
                snapshot.search_pq_l2(
                    query,
                    4,
                    subquantizers=config[0],
                    centroids=config[1],
                    iterations=config[2],
                    rerank_k=16,
                ),
            )
        var state = root[].pq[].get(config[0], config[1], config[2])
        assert_equal(state[].build_count, 1)
        assert_equal(state[].status, ARTIFACT_READY)
    assert_equal(root[].pq[].count(), 4)
    collection.close()


def test_pq_new_roots_failures_and_close_preserve_ready_owners() raises:
    var path = String("/tmp/akasha-55-pq-freshness")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var old = collection.snapshot()
    var sibling = collection.snapshot()
    var query: List[Float32] = [2.2, 3.1, 4.3, 1.7]
    var expected = old.search_pq_l2(query, 4, subquantizers=2, centroids=8)
    var old_root = old._acquire()
    var old_state = old_root[].pq[].get(2, 8, 8)
    collection.upsert(-10, query.copy())
    collection.delete(1)
    var fresh = collection.snapshot()
    var fresh_root = fresh._acquire()
    assert_equal(fresh_root[].pq[].count(), 0)
    var state = fresh_root[].pq[].get(2, 8, 8)
    state[].fail_for_test = True
    with assert_raises(contains="derived index build failed"):
        _ = fresh.search_pq_l2(query, 4, subquantizers=2, centroids=8)
    assert_equal(state[].status, ARTIFACT_FAILED)
    assert_true(not Bool(state[].ready))
    assert_equal(state[].build_count, 0)
    _same(expected, old.search_pq_l2(query, 4, subquantizers=2, centroids=8))
    state[].fail_for_test = False
    var updated = fresh.search_pq_l2(
        query, 4, subquantizers=2, centroids=8, rerank_k=16
    )
    _same(fresh.search_l2(query, 4), updated)
    assert_equal(updated[0].id, -10)
    assert_equal(state[].build_count, 1)
    collection.flush()
    var flushed = collection.snapshot()
    var flushed_root = flushed._acquire()
    assert_equal(flushed_root[].pq[].count(), 0)
    _same(
        updated,
        flushed.search_pq_l2(
            query, 4, subquantizers=2, centroids=8, rerank_k=16
        ),
    )
    old.close()
    collection.close()
    _same(
        expected, sibling.search_pq_l2(query, 4, subquantizers=2, centroids=8)
    )
    assert_equal(old_state[].build_count, 1)
    assert_equal(state[].failure_count, 1)
    _ = old_root^
    _ = fresh_root^
    _ = flushed_root^
    sibling.close()
    fresh.close()
    flushed.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_concurrent_pq_first_queries_share_parameter_bound_artifacts() raises:
    var path = String("/tmp/akasha-55-pq-concurrent")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    root[].pq[].get(2, 4, 8)[].delay_for_test = 0.1
    root[].pq[].get(2, 8, 8)[].delay_for_test = 0.1
    var query: List[Float32] = [2.2, 3.1, 4.3, 1.7]
    var expected = snapshot.search_l2(query, 4)
    var failures = List[Int](length=8, fill=0)

    def run_query(
        index: Int,
    ) {imm snapshot, imm query, imm expected, mut failures}:
        for _ in range(4):
            try:
                var actual = snapshot.search_pq_l2(
                    query,
                    4,
                    subquantizers=2,
                    centroids=4 + (index % 2) * 4,
                    rerank_k=16,
                )
                _same(expected, actual)
            except:
                failures[index] += 1

    parallelize(run_query, 8, 8)
    for failure in failures:
        assert_equal(failure, 0)
    assert_equal(root[].pq[].get(2, 4, 8)[].build_count, 1)
    assert_equal(root[].pq[].get(2, 8, 8)[].build_count, 1)
    collection.close()


def test_pq_cancelled_build_never_publishes_and_can_retry() raises:
    var path = String("/tmp/akasha-55-pq-cancel")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var query: List[Float32] = [2.2, 3.1, 4.3, 1.7]
    var state = root[].pq[].get(2, 4, 8)
    # Expire during begin, after the query's initial control check.
    state[].delay_for_test = 0.2
    var token = CancellationToken()
    var deadline = Optional(
        QueryControl(
            token,
            max_candidates=16,
            deadline_ns=perf_counter_ns() + 100_000_000,
        )
    )
    with assert_raises(contains="query deadline exceeded"):
        _ = snapshot.search_pq_l2(
            query, 4, subquantizers=2, centroids=4, control=deadline
        )
    assert_equal(state[].status, ARTIFACT_FAILED)
    assert_true(not Bool(state[].ready))
    assert_equal(state[].build_count, 0)
    state[].delay_for_test = 0.0
    var expected = snapshot.search_pq_l2(query, 4, subquantizers=2, centroids=4)
    assert_equal(state[].build_count, 1)
    var cancelled = Optional(QueryControl(token, max_candidates=16))
    token.cancel()
    with assert_raises(contains="query cancelled"):
        _ = snapshot.search_pq_l2(
            query, 4, subquantizers=2, centroids=4, control=cancelled
        )
    assert_equal(state[].status, ARTIFACT_READY)
    _same(
        expected, snapshot.search_pq_l2(query, 4, subquantizers=2, centroids=4)
    )
    var live = CancellationToken()
    var limited = Optional(QueryControl(live, max_candidates=15))
    with assert_raises(contains="resource limit"):
        _ = snapshot.search_pq_dot(
            query, 4, subquantizers=2, centroids=4, control=limited
        )
    collection.close()


def test_pq_invalid_keys_and_empty_snapshot_do_not_retain_artifacts() raises:
    var path = String("/tmp/akasha-55-pq-validation")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    var empty = collection.snapshot()
    var empty_root = empty._acquire()
    var query: List[Float32] = [2.2, 3.1, 4.3, 1.7]
    assert_equal(
        len(empty.search_pq_l2(query, 4, subquantizers=2, centroids=4)), 0
    )
    assert_equal(empty_root[].pq[].count(), 0)
    _seed(collection)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var configs: List[Tuple[Int, Int, Int]] = [
        (0, 4, 8),
        (3, 4, 8),
        (2, 0, 8),
        (2, 17, 8),
        (2, 4, 0),
    ]
    for config in configs:
        with assert_raises():
            _ = snapshot.search_pq_l2(
                query,
                4,
                subquantizers=config[0],
                centroids=config[1],
                iterations=config[2],
            )
    assert_equal(root[].pq[].count(), 0)
    collection.close()


def test_pq_training_cooperatively_stops_on_deadline() raises:
    var vectors = _training_vectors()
    var token = CancellationToken()
    var control = Optional(
        QueryControl(
            token,
            max_candidates=len(vectors),
            deadline_ns=perf_counter_ns() + 20_000_000,
        )
    )
    with assert_raises(contains="query deadline exceeded"):
        _ = PqCodebook.train(
            vectors, 2, 4, iterations=1_000_000, control=control
        )
    var fresh = PqCodebook.train(vectors, 2, 4)
    assert_equal(len(fresh.encode(vectors[0])), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
