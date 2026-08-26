from akasha import PersistentCollection
from akasha.query.control import CancellationToken, QueryControl
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_raises, TestSuite
from std.time import perf_counter_ns


def _reset(path: String) raises:
    ensure_directory(path)
    remove_file_if_exists(path + "/manifest.bin")
    remove_file_if_exists(path + "/wal.bin")
    remove_file_if_exists(path + "/sparse.wal")


def test_query_control_enforces_cancellation_deadline_and_budget() raises:
    var token = CancellationToken()
    var cancelled = QueryControl(token, max_candidates=10)
    token.cancel()
    with assert_raises():
        cancelled.checkpoint(0)

    var live = CancellationToken()
    var expired = QueryControl(
        live, max_candidates=10, deadline_ns=perf_counter_ns() - 1
    )
    with assert_raises():
        expired.checkpoint(0)
    with assert_raises():
        expired.validate_candidate_count(11)


def test_controlled_exact_search_matches_oracle_and_rejects_limit() raises:
    var path = String("/tmp/akasha-phase15-query-control")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    for id in range(20):
        collection.upsert(id, [Float32(id), Float32(20 - id)])
    var snapshot = collection.snapshot()
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=20)
    var expected = snapshot.search_dot([1.0, -0.5], 5)
    var actual = snapshot.search_dot_controlled([1.0, -0.5], 5, control)
    for index in range(len(expected)):
        assert_equal(actual[index].id, expected[index].id)
        assert_equal(actual[index].score, expected[index].score)

    var limited_token = CancellationToken()
    var limited = QueryControl(limited_token, max_candidates=19)
    with assert_raises():
        _ = snapshot.search_l2_controlled([1.0, 1.0], 2, limited)
    snapshot.close()
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
