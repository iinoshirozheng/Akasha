from akasha.storage.committed_compaction import compact_committed_segments
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.native_worker import NativeWorker
from akasha.storage.retired_files import RetiredFileQueue
from std.memory import ArcPointer
from std.utils import BlockingScopedLock, BlockingSpinLock


comptime DEFAULT_MAINTENANCE_LIBRARY = ".build/native/libakasha_worker.so"


struct _MaintenanceState(Movable):
    var path: String
    var dimension: Int
    var writer_lock: ArcPointer[BlockingSpinLock]
    var pins: ArcPointer[GenerationPinRegistry]
    var retired: ArcPointer[RetiredFileQueue]
    var status_lock: BlockingSpinLock
    var error_message: String
    var run_count: Int
    var compaction_count: Int

    def __init__(
        out self,
        path: String,
        dimension: Int,
        var writer_lock: ArcPointer[BlockingSpinLock],
        var pins: ArcPointer[GenerationPinRegistry],
        var retired: ArcPointer[RetiredFileQueue],
    ):
        self.path = String(copy=path)
        self.dimension = dimension
        self.writer_lock = writer_lock^
        self.pins = pins^
        self.retired = retired^
        self.status_lock = BlockingSpinLock()
        self.error_message = String()
        self.run_count = 0
        self.compaction_count = 0

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


def _maintenance_entry(context: OpaquePointer[MutAnyOrigin]) abi("C") -> Int32:
    var state = context.unsafe_bitcast[_MaintenanceState]()
    try:
        with BlockingScopedLock(state[].writer_lock[]):
            var result = compact_committed_segments(
                state[].path, state[].dimension
            )
            var did_compact = result.compacted
            if did_compact:
                state[].retired[].retire_or_reclaim(
                    state[].path,
                    result.previous_generation,
                    result.removed_files,
                    state[].pins,
                )
            state[].record_success(did_compact)
        return 0
    except error:
        state[].record_failure(String(error))
        return 1


struct MaintenanceController(Movable):
    """Own the background worker and its shared, heap-stable state."""

    var _state: ArcPointer[_MaintenanceState]
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

    def enabled(self) -> Bool:
        return self._enabled and not self._closed

    def request(mut self) raises -> Bool:
        if not self.enabled():
            return False
        self._raise_failure()
        return self._worker.value().request()

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

    def _raise_failure(mut self) raises:
        var message = self._state[].failure()
        if message.byte_length() > 0:
            raise Error("background maintenance failed: " + message)
