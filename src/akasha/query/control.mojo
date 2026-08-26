from std.memory import ArcPointer
from std.time import perf_counter_ns
from std.utils import BlockingScopedLock, BlockingSpinLock


struct _CancellationState:
    var lock: BlockingSpinLock
    var cancelled: Bool

    def __init__(out self):
        self.lock = BlockingSpinLock()
        self.cancelled = False


struct CancellationToken(Movable):
    var _state: ArcPointer[_CancellationState]

    def __init__(out self):
        self._state = ArcPointer(_CancellationState())

    def cancel(mut self):
        with BlockingScopedLock(self._state[].lock):
            self._state[].cancelled = True

    def is_cancelled(self) -> Bool:
        with BlockingScopedLock(self._state[].lock):
            return self._state[].cancelled


struct QueryControl(Movable):
    """Cooperative exact-query cancellation, deadline, and scan budget."""

    var _state: ArcPointer[_CancellationState]
    var max_candidates: Int
    var deadline_ns: Int

    def __init__(
        out self,
        token: CancellationToken,
        *,
        max_candidates: Int,
        deadline_ns: Int = 0,
    ) raises:
        if max_candidates <= 0:
            raise Error("query candidate limit must be positive")
        if deadline_ns < 0:
            raise Error("query deadline cannot be negative")
        self._state = token._state
        self.max_candidates = max_candidates
        self.deadline_ns = deadline_ns

    def validate_candidate_count(self, count: Int) raises:
        if count < 0 or count > self.max_candidates:
            raise Error("query candidate resource limit exceeded")

    def checkpoint(self, ordinal: Int) raises:
        if ordinal < 0:
            raise Error("query checkpoint ordinal cannot be negative")
        # Callers use deterministic intervals; ordinal zero always checks.
        if ordinal != 0 and ordinal % 256 != 0:
            return
        with BlockingScopedLock(self._state[].lock):
            if self._state[].cancelled:
                raise Error("query cancelled")
        if self.deadline_ns > 0 and perf_counter_ns() >= self.deadline_ns:
            raise Error("query deadline exceeded")
