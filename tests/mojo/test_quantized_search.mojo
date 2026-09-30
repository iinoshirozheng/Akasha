from akasha import PersistentCollection
from akasha.index.artifact_state import (
    ARTIFACT_ABSENT,
    ARTIFACT_BUILDING,
    ARTIFACT_FAILED,
    ARTIFACT_READY,
    ArtifactState,
)
from akasha.index.flat import SearchResult
from akasha.index.quantization import Sq8Index
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from max.algorithm import parallelize
from std.memory import ArcPointer
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(path: String) raises:
    ensure_directory(path)
    remove_file_if_exists(path + "/manifest.bin")
    remove_file_if_exists(path + "/manifest.bin.tmp")
    remove_file_if_exists(path + "/wal.bin")
    remove_file_if_exists(path + "/wal.bin.tmp")
    remove_file_if_exists(path + "/sparse.wal")
    remove_file_if_exists(path + "/sparse.wal.tmp")


def _vector(id: Int) -> List[Float32]:
    return [
        Float32(id % 11),
        Float32((id * 3) % 17),
        Float32((id * 7) % 13),
        Float32(id) / 10.0,
    ]


def _seed(mut collection: PersistentCollection) raises:
    for id in range(1, 65):
        collection.upsert(id, _vector(id))


def _oracle() raises -> Sq8Index:
    """The query-time build #54 removed: one SQ8 index over the seeded rows."""
    var ids = List[Int](capacity=64)
    var vectors = List[List[Float32]](capacity=64)
    for id in range(1, 65):
        ids.append(id)
        vectors.append(_vector(id))
    return Sq8Index.build(ids, vectors)


def _same(expected: List[SearchResult], actual: List[SearchResult]) raises:
    assert_equal(len(actual), len(expected))
    for rank in range(len(expected)):
        assert_equal(actual[rank].id, expected[rank].id)
        assert_equal(actual[rank].score, expected[rank].score)


def test_snapshot_sq8_exact_rerank_matches_scalar_oracle() raises:
    var path = String("/tmp/akasha-phase12-sq8-rerank")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var snapshot = collection.snapshot()
    var query: List[Float32] = [3.2, 7.4, 5.1, 2.2]

    var exact_dot = snapshot.search_dot(query, 5)
    var exact_l2 = snapshot.search_l2(query, 5)
    var exact_cosine = snapshot.search_cosine(query, 5)
    var sq8_dot = snapshot.search_sq8_dot(query, 5, rerank_k=32)
    var sq8_l2 = snapshot.search_sq8_l2(query, 5, rerank_k=32)
    var sq8_cosine = snapshot.search_sq8_cosine(query, 5, rerank_k=32)
    for index in range(5):
        assert_equal(sq8_dot[index].id, exact_dot[index].id)
        assert_equal(sq8_l2[index].id, exact_l2[index].id)
        assert_equal(sq8_cosine[index].id, exact_cosine[index].id)
        assert_equal(sq8_dot[index].score, exact_dot[index].score)
        assert_equal(sq8_l2[index].score, exact_l2[index].score)
        assert_equal(sq8_cosine[index].score, exact_cosine[index].score)
    collection.close()


def test_snapshot_sq8_approximate_surface_and_validation() raises:
    var path = String("/tmp/akasha-phase12-sq8-validation")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1.0, 0.0])
    collection.upsert(2, [2.0, 0.0])
    collection.upsert(3, [0.0, 1.0])
    var snapshot = collection.snapshot()

    assert_equal(snapshot.search_sq8_dot([1.0, 0.0], 1)[0].id, 2)
    with assert_raises():
        _ = snapshot.search_sq8_dot([1.0, 0.0], 2, rerank_k=1)
    with assert_raises():
        _ = snapshot.search_sq8_l2([1.0], 1)
    collection.close()


def test_sq8_artifact_is_built_once_per_root_and_matches_query_time_oracle() raises:
    var path = String("/tmp/akasha-54-sq8-build-once")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    assert_equal(root[].sq8[].status, ARTIFACT_ABSENT)
    assert_equal(root[].sq8[].build_count, 0)
    assert_false(Bool(root[].sq8[].ready))

    var oracle = _oracle()
    var query: List[Float32] = [3.2, 7.4, 5.1, 2.2]
    for _ in range(3):
        _same(oracle.search_dot(query, 5), snapshot.search_sq8_dot(query, 5))
        _same(oracle.search_l2(query, 7), snapshot.search_sq8_l2(query, 7))
        _same(
            oracle.search_cosine(query, 5),
            snapshot.search_sq8_cosine(query, 5),
        )
        _same(
            snapshot.search_dot(query, 5),
            snapshot.search_sq8_dot(query, 5, rerank_k=32),
        )
        _same(
            snapshot.search_l2(query, 5),
            snapshot.search_sq8_l2(query, 5, rerank_k=32),
        )
        _same(
            snapshot.search_cosine(query, 5),
            snapshot.search_sq8_cosine(query, 5, rerank_k=32),
        )
    assert_equal(root[].sq8[].status, ARTIFACT_READY)
    assert_equal(root[].sq8[].build_count, 1)
    assert_equal(root[].sq8[].ready.value()[].point_count(), 64)

    # A second handle of the same root shares the artifact without a build.
    var sibling = collection.snapshot()
    assert_true(sibling._acquire()[].sq8 is root[].sq8)
    _same(oracle.search_l2(query, 5), sibling.search_sq8_l2(query, 5))
    assert_equal(root[].sq8[].build_count, 1)
    _ = root^
    sibling.close()
    snapshot.close()
    collection.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_sq8_artifact_is_fresh_per_root_after_update_and_layout_change() raises:
    var path = String("/tmp/akasha-54-sq8-freshness")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var query: List[Float32] = [1.0, 0.0, 0.0, 0.0]
    var old = collection.snapshot()
    var before = old.search_sq8_dot(query, 3)
    assert_equal(before[0].id, 10)
    var old_root = old._acquire()
    assert_equal(old_root[].sq8[].build_count, 1)

    # Same generation, newer sequence: a new root with its own absent state.
    collection.upsert(7, [1000.0, 0.0, 0.0, 0.0])
    var updated = collection.snapshot()
    var updated_root = updated._acquire()
    assert_equal(updated.generation(), old.generation())
    assert_true(updated.last_sequence() > old.last_sequence())
    assert_false(updated_root[].sq8 is old_root[].sq8)
    assert_equal(updated_root[].sq8[].status, ARTIFACT_ABSENT)
    assert_equal(updated.search_sq8_dot(query, 3)[0].id, 7)
    assert_equal(updated_root[].sq8[].build_count, 1)
    # The old root keeps serving its own ready artifact.
    _same(before, old.search_sq8_dot(query, 3))
    assert_equal(old_root[].sq8[].build_count, 1)

    # Layout change without a data change: a new generation and root whose
    # rebuilt artifact answers exactly like the previous root's.
    var expected_l2 = updated.search_sq8_l2(query, 5, rerank_k=16)
    var expected_cosine = updated.search_sq8_cosine(query, 5)
    collection.flush()
    var checkpointed = collection.snapshot()
    var checkpointed_root = checkpointed._acquire()
    assert_true(checkpointed.generation() > updated.generation())
    assert_false(checkpointed_root[].sq8 is updated_root[].sq8)
    _same(expected_l2, checkpointed.search_sq8_l2(query, 5, rerank_k=16))
    _same(expected_cosine, checkpointed.search_sq8_cosine(query, 5))
    assert_equal(checkpointed_root[].sq8[].build_count, 1)
    assert_equal(updated_root[].sq8[].build_count, 1)
    _ = old_root^
    _ = updated_root^
    _ = checkpointed_root^
    old.close()
    updated.close()
    checkpointed.close()
    collection.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_failed_sq8_build_publishes_nothing_and_keeps_the_ready_artifact() raises:
    var path = String("/tmp/akasha-54-sq8-failure")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var query: List[Float32] = [3.2, 7.4, 5.1, 2.2]
    var old = collection.snapshot()
    var expected = old.search_sq8_dot(query, 5)
    var old_root = old._acquire()

    collection.upsert(65, [9.0, 9.0, 9.0, 9.0])
    var latest = collection.snapshot()
    var root = latest._acquire()
    root[].sq8[].fail_for_test = True
    with assert_raises(contains="failed for test"):
        _ = latest.search_sq8_dot(query, 5)
    assert_equal(root[].sq8[].status, ARTIFACT_FAILED)
    assert_false(Bool(root[].sq8[].ready))
    assert_equal(root[].sq8[].build_count, 0)
    assert_equal(root[].sq8[].failure_count, 1)
    # The failure touched only its own root; the ready artifact still serves.
    _same(expected, old.search_sq8_dot(query, 5))
    assert_equal(old_root[].sq8[].status, ARTIFACT_READY)
    assert_equal(old_root[].sq8[].build_count, 1)

    # Failed is not terminal: the next query builds and publishes.
    root[].sq8[].fail_for_test = False
    _same(
        latest.search_dot(query, 5),
        latest.search_sq8_dot(query, 5, rerank_k=32),
    )
    assert_equal(root[].sq8[].status, ARTIFACT_READY)
    assert_equal(root[].sq8[].build_count, 1)
    assert_equal(root[].sq8[].failure_count, 1)
    assert_equal(root[].sq8[].ready.value()[].point_count(), 65)
    _ = old_root^
    _ = root^
    old.close()
    latest.close()
    collection.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_sq8_artifact_survives_sibling_handle_and_collection_close() raises:
    var path = String("/tmp/akasha-54-sq8-close")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var query: List[Float32] = [3.2, 7.4, 5.1, 2.2]
    var first = collection.snapshot()
    var second = collection.snapshot()
    var expected = first.search_sq8_cosine(query, 5)
    var root = second._acquire()
    assert_true(first._acquire()[].sq8 is root[].sq8)
    assert_equal(root[].sq8[].build_count, 1)
    first.close()
    collection.close()
    _same(expected, second.search_sq8_cosine(query, 5))
    _same(expected, second.search_sq8_cosine(query, 5))
    assert_equal(root[].sq8[].status, ARTIFACT_READY)
    assert_equal(root[].sq8[].build_count, 1)
    with assert_raises(contains="snapshot is closed"):
        _ = first.search_sq8_cosine(query, 5)
    _ = root^
    second.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_concurrent_first_sq8_queries_build_once_and_share_ready() raises:
    var path = String("/tmp/akasha-54-sq8-concurrent")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _seed(collection)
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    root[].sq8[].delay_for_test = 0.2
    var query: List[Float32] = [3.2, 7.4, 5.1, 2.2]
    var expected = _oracle().search_l2(query, 5)
    var failures = List[Int](length=8, fill=0)

    def run_query(
        index: Int,
    ) {imm snapshot, imm query, imm expected, mut failures}:
        for _ in range(4):
            try:
                var actual = snapshot.search_sq8_l2(query, 5)
                if len(actual) != len(expected):
                    failures[index] += 1
                    continue
                for rank in range(len(expected)):
                    if (
                        actual[rank].id != expected[rank].id
                        or actual[rank].score != expected[rank].score
                    ):
                        failures[index] += 1
            except:
                failures[index] += 1

    parallelize(run_query, 8, 8)
    for failure in failures:
        assert_equal(failure, 0)
    assert_equal(root[].sq8[].status, ARTIFACT_READY)
    assert_equal(root[].sq8[].build_count, 1)
    assert_equal(root[].sq8[].failure_count, 0)
    _ = root^
    snapshot.close()
    collection.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_artifact_state_keeps_the_first_ready_artifact() raises:
    var state = ArtifactState[List[Int]]()
    assert_equal(state.status, ARTIFACT_ABSENT)
    state.begin()
    assert_equal(state.status, ARTIFACT_BUILDING)
    state.fail("first attempt")
    assert_equal(state.status, ARTIFACT_FAILED)
    assert_false(Bool(state.ready))
    assert_equal(state.failure, "first attempt")
    assert_equal(state.failure_count, 1)
    assert_equal(state.build_count, 0)

    state.begin()
    var payload: List[Int] = [1, 2, 3]
    state.publish(ArcPointer(payload^))
    assert_equal(state.status, ARTIFACT_READY)
    assert_equal(len(state.ready.value()[]), 3)
    assert_equal(state.build_count, 1)

    # A later or failed build never replaces the ready artifact.
    var stale: List[Int] = [9]
    state.publish(ArcPointer(stale^))
    assert_equal(len(state.ready.value()[]), 3)
    assert_equal(state.build_count, 1)
    state.fail("late failure")
    assert_equal(state.status, ARTIFACT_READY)
    assert_equal(state.failure_count, 2)
    assert_equal(len(state.ready.value()[]), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
