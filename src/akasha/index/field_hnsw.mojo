"""Independent dense-field HNSW artifacts owned by an immutable read run."""

from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswIdOrdinalLookup
from std.utils import BlockingSpinLock


struct FieldHnswIndex(Movable):
    var index: HnswIndex
    # Run-local MemTable ordinals in graph insertion order.
    var rows: List[Int]
    var authority_scalar: UInt8
    var lookup: HnswIdOrdinalLookup
    var query_lock: BlockingSpinLock
    var cache_hit: Bool
    var cache_published: Bool

    def __init__(
        out self,
        var index: HnswIndex,
        var rows: List[Int],
        authority_scalar: UInt8,
        var lookup: HnswIdOrdinalLookup,
        cache_hit: Bool = False,
    ):
        self.index = index^
        self.rows = rows^
        self.authority_scalar = authority_scalar
        self.lookup = lookup^
        self.query_lock = BlockingSpinLock()
        self.cache_hit = cache_hit
        self.cache_published = cache_hit
