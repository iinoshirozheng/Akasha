from akasha.common.config import CollectionConfig
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_admission import HnswResultAdmission
from akasha.query.control import CancellationToken, QueryControl
from akasha.storage.filesystem import ensure_directory, write_file_sync
from akasha.storage.hnsw_store import encode_hnsw_snapshot, open_hnsw_snapshot_view
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


struct _CancelState:
    var token: CancellationToken
    var checks: Int
    var cancel_at: Int

    def __init__(out self, var token: CancellationToken, cancel_at: Int):
        self.token = token^
        self.checks = 0
        self.cancel_at = cancel_at


struct CancelDuringTraversal(HnswResultAdmission):
    var state: ArcPointer[_CancelState]

    def __init__(out self, var token: CancellationToken, cancel_at: Int):
        self.state = ArcPointer(_CancelState(token^, cancel_at))

    def is_allow_all(self) -> Bool:
        return False

    def validate(self, slot_count: Int) raises:
        if slot_count < 0:
            raise Error("invalid test graph")

    def _allows_item(self, slot: UInt32, id: Int) raises -> Bool:
        self.state[].checks += 1
        if self.state[].checks == self.state[].cancel_at:
            self.state[].token.cancel()
        return True


def _fixture(level: Int) raises -> HnswIndex:
    var config = CollectionConfig.defaults(1)
    config.m = 2
    config.m0 = 4
    var index = HnswIndex(config)
    for id in range(100):
        index._insert_prepared[-1](id, [Float32(id)], level, False, id > 0)
    return index^


def test_owned_base_and_upper_traversal_observe_mid_search_cancellation() raises:
    for level in range(2):
        var index = _fixture(level)
        var token = CancellationToken()
        var control = Optional(QueryControl(token, max_candidates=100))
        var allowed = CancelDuringTraversal(token^, 8)
        with assert_raises(contains="query cancelled"):
            _ = index._search_bound([90.0], 10, 100, allowed, control=control)
        assert_true(allowed.state[].token.is_cancelled())
        assert_true(allowed.state[].checks >= 8)
        assert_true(allowed.state[].checks < 100)
        # Scratch from an interrupted query must remain reusable.
        var result = index.search([90.0], 1, ef_search=100)
        assert_equal(result[0].id, 90)


def test_mapped_widening_observes_mid_search_cancellation() raises:
    var index = _fixture(1)
    var config = index.config.copy()
    ensure_directory("/tmp/akasha-hnsw-control")
    var path = String("/tmp/akasha-hnsw-control/graph.bin")
    write_file_sync(path, encode_hnsw_snapshot(index, UInt64(1)))
    var mapped = open_hnsw_snapshot_view(path, config, UInt64(1))
    var token = CancellationToken()
    var control = Optional(QueryControl(token, max_candidates=100))
    var allowed = CancelDuringTraversal(token^, 8)
    with assert_raises(contains="query cancelled"):
        _ = mapped._search_admitted_with_actual_widening(
            [90.0], 10, 16, 100, 100, allowed, False, False, control=control
        )
    assert_true(allowed.state[].checks >= 8)
    assert_true(allowed.state[].checks < 100)
    var result = mapped.search([90.0], 1, ef_search=100)
    assert_equal(result[0].id, 90)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
