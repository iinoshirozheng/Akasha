"""Mapped ordinal postings with a bounded, synchronized LRU of decoded sets."""
from std.sys import size_of
from std.memory import ArcPointer
from std.utils import BlockingScopedLock, BlockingSpinLock
from akasha.storage.index_cache import MappedCacheArtifact
from akasha.index.roaring_rows import RoaringRowSet
from akasha.query.control import QueryControl


@fieldwise_init
struct PostingLocation(Copyable, Movable):
    var offset: Int
    var count: Int


@fieldwise_init
struct _CachedPosting(Movable):
    var slot: Int
    var rows: RoaringRowSet


struct MappedPostings(Movable):
    var artifact: ArcPointer[MappedCacheArtifact]
    var locations: List[PostingLocation]
    var _lock: BlockingSpinLock
    var _cache: List[_CachedPosting]
    var max_bytes: Int
    var max_entries: Int
    var retained_bytes: Int
    var loads: Int
    var hits: Int
    var evictions: Int

    def __init__(out self, var artifact: ArcPointer[MappedCacheArtifact], *,
                 max_bytes: Int = 8 * 1024 * 1024, max_entries: Int = 128) raises:
        if max_bytes < 0 or max_entries < 0:
            raise Error("negative posting cache limit")
        self.artifact = artifact^
        self.locations = List[PostingLocation]()
        self._lock = BlockingSpinLock()
        self._cache = List[_CachedPosting]()
        self.max_bytes = max_bytes
        self.max_entries = max_entries
        self.retained_bytes = 0
        self.loads = 0
        self.hits = 0
        self.evictions = 0

    def load(mut self, slot: Int, control: Optional[QueryControl] = None) raises -> RoaringRowSet:
        # Serialize misses so concurrent readers cannot multiply retained pages.
        # Returned sets are independent; eviction never invalidates a query.
        with BlockingScopedLock(self._lock):
            if control:
                control.value().checkpoint(0)
            for i in range(len(self._cache)):
                if self._cache[i].slot == slot:
                    var entry = self._cache.pop(i)
                    var result = entry.rows.copy()
                    self._cache.append(entry^)
                    self.hits += 1
                    return result^
            var location = self.locations[slot].copy()
            var rows = RoaringRowSet()
            for i in range(location.count):
                if control:
                    control.value().checkpoint(i)
                _ = rows.insert(self.artifact[]._mapping.load_scalars[DType.uint64, 1](location.offset + i * 8))
            if control:
                control.value().checkpoint(0)
            self.loads += 1
            var cost = rows._bytes + size_of[_CachedPosting]()
            if self.max_entries > 0 and cost <= self.max_bytes:
                while len(self._cache) >= self.max_entries or self.retained_bytes + cost > self.max_bytes:
                    var removed = self._cache.pop(0)
                    self.retained_bytes -= removed.rows._bytes + size_of[_CachedPosting]()
                    self.evictions += 1
                self._cache.append(_CachedPosting(slot, rows.copy()))
                self.retained_bytes += cost
            return rows^
