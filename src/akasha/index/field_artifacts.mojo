"""Immutable-root field identities and shared derived artifact lifecycles."""

from akasha.index.artifact_state import ArtifactState
from std.collections import Dict
from std.memory import ArcPointer
from std.utils import BlockingScopedLock, BlockingSpinLock


struct FieldRow(Comparable, TrivialRegisterPassable):
    var id: Int
    var layer: Int
    var ordinal: Int

    def __init__(out self, id: Int, layer: Int, ordinal: Int):
        self.id = id
        self.layer = layer
        self.ordinal = ordinal

    def __lt__(self, other: Self) -> Bool:
        return self.id < other.id


struct FieldArtifacts[T: Deinitable & Movable](Movable):
    """Field ID is the key; root coverage/catalog/config are immutable."""

    var _lock: BlockingSpinLock
    var _states: Dict[Int, ArcPointer[ArtifactState[Self.T]]]

    def __init__(out self):
        self._lock = BlockingSpinLock()
        self._states = Dict[Int, ArcPointer[ArtifactState[Self.T]]]()

    def get(
        mut self, field_id: Int
    ) raises -> ArcPointer[ArtifactState[Self.T]]:
        with BlockingScopedLock(self._lock):
            if field_id not in self._states:
                self._states[field_id] = ArcPointer(ArtifactState[Self.T]())
            return self._states[field_id].copy()

    def count(mut self) -> Int:
        with BlockingScopedLock(self._lock):
            return len(self._states)
