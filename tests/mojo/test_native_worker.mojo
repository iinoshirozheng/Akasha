from akasha.storage.native_worker import NativeWorker
from std.memory import ArcPointer
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from std.time import sleep
from std.utils import BlockingScopedLock, BlockingSpinLock


comptime _LIBRARY = ".build/native/libakasha_worker.so"


struct _ProbeState:
    var lock: BlockingSpinLock
    var calls: Int
    var started: Bool
    var release: Bool
    var failure_code: Int32

    def __init__(out self, release: Bool, failure_code: Int32 = 0):
        self.lock = BlockingSpinLock()
        self.calls = 0
        self.started = False
        self.release = release
        self.failure_code = failure_code


def _probe_entry(context: OpaquePointer[MutAnyOrigin]) abi("C") -> Int32:
    var state = context.unsafe_bitcast[_ProbeState]()
    with BlockingScopedLock(state[].lock):
        state[].calls += 1
        state[].started = True
    while True:
        with BlockingScopedLock(state[].lock):
            if state[].release:
                return state[].failure_code
        sleep(0.001)


def _wait_until_started(state: ArcPointer[_ProbeState]) raises:
    for _ in range(10_000):
        with BlockingScopedLock(state[].lock):
            if state[].started:
                return
        sleep(0.001)
    raise Error("native worker did not start")


def test_native_worker_coalesces_to_one_pending_callback() raises:
    var state = ArcPointer(_ProbeState(False))
    var context = state.unsafe_ptr().unsafe_bitcast[NoneType]()
    var worker = NativeWorker.open(_LIBRARY, context, _probe_entry)
    assert_true(worker.request())
    _wait_until_started(state)
    for _ in range(64):
        _ = worker.request()
    assert_equal(worker.pending_count(), 1)
    with BlockingScopedLock(state[].lock):
        state[].release = True
    assert_equal(worker.drain(), Int32(0))
    assert_equal(state[].calls, 2)
    assert_equal(worker.close(), Int32(0))


def test_native_worker_propagates_callback_failure() raises:
    var state = ArcPointer(_ProbeState(True, 7))
    var context = state.unsafe_ptr().unsafe_bitcast[NoneType]()
    var worker = NativeWorker.open(_LIBRARY, context, _probe_entry)
    assert_true(worker.request())
    assert_equal(worker.drain(), Int32(7))
    with assert_raises():
        _ = worker.request()
    assert_equal(worker.close(), Int32(7))


def test_native_worker_close_joins_and_rejects_later_requests() raises:
    var state = ArcPointer(_ProbeState(True))
    var context = state.unsafe_ptr().unsafe_bitcast[NoneType]()
    var worker = NativeWorker.open(_LIBRARY, context, _probe_entry)
    assert_true(worker.request())
    assert_equal(worker.close(), Int32(0))
    assert_true(worker.is_closed())
    assert_equal(state[].calls, 1)
    with assert_raises():
        _ = worker.request()
    assert_false(worker.is_running())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
