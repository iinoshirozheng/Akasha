from akasha.storage.committed_compaction import (
    begin_compaction,
    build_compaction,
    COMPACTION_ATTEMPTS,
    CompactionInputs,
    finish_compaction,
)
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.native_worker import NativeWorker
from akasha.storage.read_generation import ReadGenerationCache, SealedMerge
from akasha.storage.retired_files import RetiredFileQueue, reclaim_retired_batch
from std.memory import ArcPointer
from std.time import sleep
from std.utils import BlockingScopedLock, BlockingSpinLock


comptime DEFAULT_MAINTENANCE_LIBRARY = ".build/native/libakasha_worker.so"


@fieldwise_init
struct CompactionCounts(ImplicitlyCopyable, Movable):
    """Background compaction jobs: captures, lost races, spent budgets."""

    var attempts: Int
    var conflicts: Int
    var exhausted: Int


struct _MaintenanceState(Movable):
    var path: String
    var dimension: Int
    var writer_lock: ArcPointer[BlockingSpinLock]
    var compaction_lock: ArcPointer[BlockingSpinLock]
    var pins: ArcPointer[GenerationPinRegistry]
    var retired: ArcPointer[RetiredFileQueue]
    var read_generations: ArcPointer[ReadGenerationCache]
    var cancelled: Bool
    """Set by the owner's close under the writer lock; jobs read it there."""
    var status_lock: BlockingSpinLock
    var error_message: String
    var run_count: Int
    var compaction_count: Int
    var compaction_requested: Bool
    var counts: CompactionCounts
    var compaction_delay_for_test: Float64
    """Seconds a job sleeps between capture and build."""

    def __init__(
        out self,
        path: String,
        dimension: Int,
        var writer_lock: ArcPointer[BlockingSpinLock],
        var pins: ArcPointer[GenerationPinRegistry],
        var retired: ArcPointer[RetiredFileQueue],
        var read_generations: ArcPointer[ReadGenerationCache],
    ):
        self.path = String(copy=path)
        self.dimension = dimension
        self.writer_lock = writer_lock^
        self.compaction_lock = ArcPointer(BlockingSpinLock())
        self.pins = pins^
        self.retired = retired^
        self.read_generations = read_generations^
        self.cancelled = False
        self.status_lock = BlockingSpinLock()
        self.error_message = String()
        self.run_count = 0
        self.compaction_count = 0
        self.compaction_requested = False
        self.counts = CompactionCounts(0, 0, 0)
        self.compaction_delay_for_test = 0

    def record_success(mut self, compacted: Bool):
        with BlockingScopedLock(self.status_lock):
            self.run_count += 1
            if compacted:
                self.compaction_count += 1

    def record_failure(mut self, message: String):
        with BlockingScopedLock(self.status_lock):
            if self.error_message.byte_length() == 0:
                self.error_message = String(copy=message)

    def failure(mut self) -> String:
        with BlockingScopedLock(self.status_lock):
            return String(copy=self.error_message)

    def runs(mut self) -> Int:
        with BlockingScopedLock(self.status_lock):
            return self.run_count

    def request_compaction(mut self):
        with BlockingScopedLock(self.status_lock):
            self.compaction_requested = True

    def take_compaction_request(mut self) -> Bool:
        with BlockingScopedLock(self.status_lock):
            var requested = self.compaction_requested
            self.compaction_requested = False
            return requested

    def compaction_counts(mut self) -> CompactionCounts:
        with BlockingScopedLock(self.status_lock):
            return self.counts

    def count_attempt(mut self):
        with BlockingScopedLock(self.status_lock):
            self.counts.attempts += 1

    def count_conflict(mut self):
        with BlockingScopedLock(self.status_lock):
            self.counts.conflicts += 1

    def count_exhausted(mut self):
        with BlockingScopedLock(self.status_lock):
            self.counts.exhausted += 1


def _maintenance_entry(context: OpaquePointer[MutAnyOrigin]) abi("C") -> Int32:
    var state = context.unsafe_bitcast[_MaintenanceState]()
    try:
        _merge_sealed_runs(state[])
        var compacted = False
        if state[].take_compaction_request():
            compacted = _compact(state[])
        state[].record_success(compacted)
        return 0
    except error:
        state[].record_failure(String(error))
        return 1


def _merge_sealed_runs(mut state: _MaintenanceState) raises:
    """Merge the sealed-run prefix outside the writer lock, then publish it.

    A merge captured before the publisher reset is stale; publish drops it.
    """
    var merge: Optional[SealedMerge]
    with BlockingScopedLock(state.writer_lock[]):
        if state.cancelled or not state.read_generations[].merge_due():
            return
        merge = Optional(state.read_generations[].capture_merge())
    merge.value().build()
    with BlockingScopedLock(state.writer_lock[]):
        if not state.cancelled:
            _ = state.read_generations[].publish_merge(merge.take())


def _compact(mut state: _MaintenanceState) raises -> Bool:
    """Run the foreground job's steps; the build holds no writer lock.

    Spending the retry budget is counted, not a failure: a failure closes
    every operation of the owner, while the next request simply retries.
    A cancelled job discards its output and is not a failure either.
    """
    with BlockingScopedLock(state.compaction_lock[]):
        for _ in range(COMPACTION_ATTEMPTS):
            var inputs: Optional[CompactionInputs]
            with BlockingScopedLock(state.writer_lock[]):
                if state.cancelled:
                    return False
                inputs = begin_compaction(
                    state.path, state.dimension, state.pins
                )
                if inputs:
                    state.count_attempt()
            if not inputs:
                return False
            if state.compaction_delay_for_test > 0:
                sleep(state.compaction_delay_for_test)
            var output = build_compaction(
                state.path, state.dimension, inputs.value(), state.pins
            )
            var published: Bool
            var cancelled: Bool
            with BlockingScopedLock(state.writer_lock[]):
                cancelled = state.cancelled
                published = finish_compaction(
                    state.path,
                    state.dimension,
                    inputs.value(),
                    output,
                    cancelled,
                    state.pins,
                    state.retired,
                    state.read_generations,
                )
                if not published and not cancelled:
                    state.count_conflict()
            if published:
                reclaim_retired_batch(
                    state.path, state.retired, state.writer_lock
                )
                return True
            if cancelled:
                return False
        state.count_exhausted()
        return False


struct MaintenanceController(Movable):
    """Own the background worker and its shared, heap-stable state."""

    var _state: ArcPointer[_MaintenanceState]
    # Acquire before the writer lock, never while holding it. All full
    # compactions overlap, so serialize builders without blocking writers.
    var compaction_lock: ArcPointer[BlockingSpinLock]
    var _worker: Optional[NativeWorker]
    var _enabled: Bool
    var _closed: Bool

    def __init__(
        out self,
        var state: ArcPointer[_MaintenanceState],
        var worker: Optional[NativeWorker],
        enabled: Bool,
    ):
        self._state = state^
        self.compaction_lock = self._state[].compaction_lock
        self._worker = worker^
        self._enabled = enabled
        self._closed = False

    @staticmethod
    def start(
        path: String,
        dimension: Int,
        writer_lock: ArcPointer[BlockingSpinLock],
        pins: ArcPointer[GenerationPinRegistry],
        retired: ArcPointer[RetiredFileQueue],
        read_generations: ArcPointer[ReadGenerationCache],
        library_path: String,
    ) -> MaintenanceController:
        var owned_writer_lock = writer_lock
        var owned_pins = pins
        var owned_retired = retired
        var state = ArcPointer(
            _MaintenanceState(
                path,
                dimension,
                owned_writer_lock^,
                owned_pins^,
                owned_retired^,
                read_generations,
            )
        )
        try:
            var context = state.unsafe_ptr().unsafe_bitcast[NoneType]()
            var worker = NativeWorker.open(
                library_path, context, _maintenance_entry
            )
            var optional = Optional(worker^)
            return MaintenanceController(state^, optional^, True)
        except:
            var no_worker = Optional[NativeWorker]()
            return MaintenanceController(state^, no_worker^, False)

    def __deinit__(deinit self):
        if self._enabled and not self._closed:
            try:
                _ = self._worker.value().close()
            except:
                pass
        # The worker reaches the state through a raw pointer; without this
        # last use the field is destroyed before the join above.
        _ = self._state^

    def enabled(self) -> Bool:
        return self._enabled and not self._closed

    def request_compaction(mut self) raises -> Bool:
        if not self.enabled():
            return False
        self._raise_failure()
        self._state[].request_compaction()
        return self._worker.value().request()

    def request_merge(mut self):
        """Best effort: a refused request leaves the runs to backpressure,
        and the failure or close that refused it ends the wait."""
        if not self.enabled():
            return
        try:
            _ = self._worker.value().request()
        except:
            pass

    def cancel(mut self):
        """Stop jobs from publishing; the caller holds the writer lock."""
        self._state[].cancelled = True

    def compaction_counts(mut self) -> CompactionCounts:
        return self._state[].compaction_counts()

    def wait(mut self) raises -> Bool:
        if not self.enabled():
            return False
        var status = self._worker.value().drain()
        if status != 0:
            self._raise_failure()
            raise Error("background maintenance worker failed")
        self._raise_failure()
        return self._state[].runs() > 0

    def close(mut self) raises:
        if self._closed:
            self._raise_failure()
            return
        self._closed = True
        if not self._enabled:
            return
        var status = self._worker.value().close()
        if status != 0:
            self._raise_failure()
            raise Error("background maintenance worker failed")
        self._raise_failure()

    def check(self) raises:
        self._raise_failure()

    def _raise_failure(self) raises:
        var message = self._state[].failure()
        if message.byte_length() > 0:
            raise Error("background maintenance failed: " + message)
