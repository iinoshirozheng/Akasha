"""Root-owned JSON bitmaps keyed by exact projection and learned type."""
from akasha.index.artifact_state import ArtifactState
from akasha.index.lance_json_stream import LanceJsonBitmapIndex
from std.collections import Dict
from std.memory import ArcPointer
from std.utils import BlockingScopedLock, BlockingSpinLock


struct JsonArtifacts(Movable):
    var _lock: BlockingSpinLock
    var _states: Dict[Tuple[String, String, Int], ArcPointer[ArtifactState[LanceJsonBitmapIndex]]]

    def __init__(out self):
        self._lock = BlockingSpinLock()
        self._states = Dict[Tuple[String, String, Int], ArcPointer[ArtifactState[LanceJsonBitmapIndex]]]()

    def get(mut self, column: String, path: String, target: Int) raises -> ArcPointer[ArtifactState[LanceJsonBitmapIndex]]:
        with BlockingScopedLock(self._lock):
            var key = (column.copy(), path.copy(), target)
            if key not in self._states:
                if len(self._states) >= 256:
                    raise Error("JSON snapshot artifact count limit exceeded")
                self._states[key] = ArcPointer(ArtifactState[LanceJsonBitmapIndex]())
            return self._states[key].copy()
