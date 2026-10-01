"""Immutable IVF-flat membership and training-key lifecycle on one read root."""

from akasha.index.artifact_state import ArtifactState
from akasha.index.field_artifacts import FieldRow
from std.collections import Dict
from std.memory import ArcPointer
from std.utils import BlockingScopedLock, BlockingSpinLock


struct IvfOptions(Copyable, Movable):
    var nlist: Int
    var nprobe: Int
    var iterations: Int

    def __init__(
        out self, nlist: Int = 32, nprobe: Int = 4, iterations: Int = 8
    ):
        self.nlist = nlist
        self.nprobe = nprobe
        self.iterations = iterations

    def validate(self) raises:
        if (
            self.nlist <= 0
            or self.nlist > 256
            or self.nprobe <= 0
            or self.nprobe > self.nlist
            or self.iterations <= 0
        ):
            raise Error(
                "IVF requires 1..256 lists, 1..nlist probes and positive"
                " iterations"
            )


@fieldwise_init
struct FieldIvfIndex(Movable):
    var rows: List[FieldRow]
    var centroids: List[List[Float32]]
    var partitions: List[List[Int]]


struct FieldIvfArtifacts(Movable):
    var _lock: BlockingSpinLock
    var _states: Dict[
        Tuple[Int, Int, Int], ArcPointer[ArtifactState[FieldIvfIndex]]
    ]

    def __init__(out self):
        self._lock = BlockingSpinLock()
        self._states = Dict[
            Tuple[Int, Int, Int], ArcPointer[ArtifactState[FieldIvfIndex]]
        ]()

    def get(
        mut self, field_id: Int, nlist: Int, iterations: Int
    ) raises -> ArcPointer[ArtifactState[FieldIvfIndex]]:
        with BlockingScopedLock(self._lock):
            var key = (field_id, nlist, iterations)
            if key not in self._states:
                self._states[key] = ArcPointer(ArtifactState[FieldIvfIndex]())
            return self._states[key].copy()

    def count(mut self) -> Int:
        with BlockingScopedLock(self._lock):
            return len(self._states)
