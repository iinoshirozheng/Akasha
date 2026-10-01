"""Independent dense-field HNSW artifacts owned by an immutable read root."""

from akasha.index.field_artifacts import FieldRow
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswIdOrdinalLookup
from std.utils import BlockingSpinLock


struct FieldHnswIndex(Movable):
    var index: HnswIndex
    var rows: List[FieldRow]
    var lookup: HnswIdOrdinalLookup
    var query_lock: BlockingSpinLock

    def __init__(
        out self,
        var index: HnswIndex,
        var rows: List[FieldRow],
        var lookup: HnswIdOrdinalLookup,
    ):
        self.index = index^
        self.rows = rows^
        self.lookup = lookup^
        self.query_lock = BlockingSpinLock()
