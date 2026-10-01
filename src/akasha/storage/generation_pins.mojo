from std.utils import BlockingScopedLock, BlockingSpinLock
from akasha.storage.file_leases import ManifestFileLease


struct _GenerationPin(Movable):
    var generation: UInt64
    var count: Int
    var lease: Optional[ManifestFileLease]

    def __init__(
        out self,
        generation: UInt64,
        count: Int,
        var lease: Optional[ManifestFileLease],
    ):
        self.generation = generation
        self.count = count
        self.lease = lease^


struct GenerationPinRegistry(Movable):
    """Locked counts for manifest generations held by read snapshots."""

    var _lock: BlockingSpinLock
    var _pins: List[_GenerationPin]
    var _directory: String
    var _dimension: Int
    var _cleanup_error: String

    def __init__(out self, directory: String = "", dimension: Int = 0):
        self._lock = BlockingSpinLock()
        self._pins = List[_GenerationPin]()
        self._directory = directory.copy()
        self._dimension = dimension
        self._cleanup_error = ""

    def pin(mut self, generation: UInt64) raises:
        with BlockingScopedLock(self._lock):
            for index in range(len(self._pins)):
                if self._pins[index].generation == generation:
                    self._pins[index].count += 1
                    return
            var lease = Optional[ManifestFileLease]()
            if generation > 0 and self._directory.byte_length() > 0:
                lease = Optional(
                    ManifestFileLease(
                        self._directory, self._dimension, generation
                    )
                )
            self._pins.append(_GenerationPin(generation, 1, lease^))

    def unpin(mut self, generation: UInt64):
        var released = Optional[ManifestFileLease]()
        with BlockingScopedLock(self._lock):
            for index in range(len(self._pins)):
                if self._pins[index].generation != generation:
                    continue
                self._pins[index].count -= 1
                if self._pins[index].count == 0:
                    if self._pins[index].lease:
                        released = Optional(self._pins[index].lease.take())
                    self._pins.swap_elements(index, len(self._pins) - 1)
                    _ = self._pins.pop()
                break
        if released:
            try:
                released.value().reclaim()
            except error:
                # A destructor cannot raise. Preserve the diagnostic; explicit
                # maintenance still retries its retired paths and may raise.
                with BlockingScopedLock(self._lock):
                    self._cleanup_error = String(error)

    def cleanup_error(mut self) -> String:
        with BlockingScopedLock(self._lock):
            return self._cleanup_error.copy()

    def active_count(mut self) -> Int:
        with BlockingScopedLock(self._lock):
            var result = 0
            for index in range(len(self._pins)):
                result += self._pins[index].count
            return result
