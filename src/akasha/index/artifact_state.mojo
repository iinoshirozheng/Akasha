"""Root-owned derived-index artifacts with explicit lifecycle states.

An artifact is derived from one immutable read root, and that root is its key:
root and layout identity, the single dense field, the config fingerprint and
the source coverage are fixed for the root's lifetime, so nothing under the
artifact can go stale. The owner lives exactly as long as its root; a handle
close drops only that handle's root owner and never clears an artifact another
handle or operation still uses.

States are `absent`, `building`, `ready` and `failed`. Only a complete build
publishes `ready`, shared read-only behind an `ArcPointer`; the first ready
artifact is never replaced by a later or failed build. A failed build
publishes nothing, records its message and leaves the next query free to try
again. Callers hold `lock` from the ready check through publication, so
concurrent first queries on one root wait for the builder and then share its
artifact instead of building their own.
"""

from std.memory import ArcPointer
from std.time import sleep
from std.utils import BlockingSpinLock


comptime ARTIFACT_ABSENT = 0
comptime ARTIFACT_BUILDING = 1
comptime ARTIFACT_READY = 2
comptime ARTIFACT_FAILED = 3


struct ArtifactState[T: Deinitable & Movable](Movable):
    """Lifecycle and shared ready artifact of one derived index on one root."""

    var lock: BlockingSpinLock
    var status: Int
    var ready: Optional[ArcPointer[Self.T]]
    var failure: String
    var build_count: Int
    var failure_count: Int
    var delay_for_test: Float64
    var fail_for_test: Bool

    def __init__(out self):
        self.lock = BlockingSpinLock()
        self.status = ARTIFACT_ABSENT
        self.ready = Optional[ArcPointer[Self.T]]()
        self.failure = String()
        self.build_count = 0
        self.failure_count = 0
        self.delay_for_test = 0.0
        self.fail_for_test = False

    def begin(mut self) raises:
        """Enter `building`; the injected test delay and failure act here."""
        self.status = ARTIFACT_BUILDING
        if self.delay_for_test > 0:
            sleep(self.delay_for_test)
        if self.fail_for_test:
            raise Error("derived index build failed for test")

    def publish(mut self, var artifact: ArcPointer[Self.T]):
        """Publish a complete artifact; the first ready artifact stays."""
        if self.ready:
            return
        self.ready = Optional(artifact^)
        self.status = ARTIFACT_READY
        self.build_count += 1

    def fail(mut self, message: String):
        """Record a failed build; it never demotes a ready artifact."""
        self.failure = message
        self.failure_count += 1
        if not self.ready:
            self.status = ARTIFACT_FAILED
