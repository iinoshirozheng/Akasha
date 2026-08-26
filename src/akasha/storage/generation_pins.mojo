from std.utils import BlockingScopedLock, BlockingSpinLock


struct _GenerationPin(Movable):
    var generation: UInt64
    var count: Int

    def __init__(out self, generation: UInt64, count: Int):
        self.generation = generation
        self.count = count


struct GenerationPinRegistry(Movable):
    """Locked counts for manifest generations held by read snapshots."""

    var _lock: BlockingSpinLock
    var _pins: List[_GenerationPin]

    def __init__(out self):
        self._lock = BlockingSpinLock()
        self._pins = List[_GenerationPin]()

    def pin(mut self, generation: UInt64):
        with BlockingScopedLock(self._lock):
            for index in range(len(self._pins)):
                if self._pins[index].generation == generation:
                    self._pins[index].count += 1
                    return
            self._pins.append(_GenerationPin(generation, 1))

    def unpin(mut self, generation: UInt64):
        with BlockingScopedLock(self._lock):
            for index in range(len(self._pins)):
                if self._pins[index].generation != generation:
                    continue
                self._pins[index].count -= 1
                if self._pins[index].count == 0:
                    self._pins.swap_elements(index, len(self._pins) - 1)
                    _ = self._pins.pop()
                return

    def has_pin_at_or_before(mut self, generation: UInt64) -> Bool:
        with BlockingScopedLock(self._lock):
            for index in range(len(self._pins)):
                if (
                    self._pins[index].generation <= generation
                    and self._pins[index].count > 0
                ):
                    return True
            return False

    def active_count(mut self) -> Int:
        with BlockingScopedLock(self._lock):
            var result = 0
            for index in range(len(self._pins)):
                result += self._pins[index].count
            return result
