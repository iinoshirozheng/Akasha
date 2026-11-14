"""Root-owned JSON indexes keyed by kind, exact projection and learned type."""
from akasha.index.artifact_state import ArtifactState
from akasha.index.json_scalar_index import JsonScalarIndex
from std.collections import Dict
from std.memory import ArcPointer
from std.utils import BlockingScopedLock, BlockingSpinLock


struct JsonArtifacts(Movable):
    var _lock: BlockingSpinLock
    var _states: Dict[Tuple[String, String, Int, Int], ArcPointer[ArtifactState[JsonScalarIndex]]]

    def __init__(out self):
        self._lock = BlockingSpinLock()
        self._states = Dict[Tuple[String, String, Int, Int], ArcPointer[ArtifactState[JsonScalarIndex]]]()

    def get(mut self, column: String, path: String, target: Int, kind: UInt8 = 1) raises -> ArcPointer[ArtifactState[JsonScalarIndex]]:
        if kind != 1 and kind != 2:
            raise Error("unsupported JSON index kind")
        with BlockingScopedLock(self._lock):
            var key = (column.copy(), path.copy(), target, Int(kind))
            if key not in self._states:
                if len(self._states) >= 256:
                    raise Error("JSON snapshot artifact count limit exceeded")
                self._states[key] = ArcPointer(ArtifactState[JsonScalarIndex]())
            return self._states[key].copy()
