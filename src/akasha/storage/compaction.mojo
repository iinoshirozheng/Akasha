from akasha.storage.manifest import Manifest
from std.os import SEEK_END


comptime LEVEL_ZERO_SEGMENT_LIMIT = 8
"""Level-zero segments at which a flush waits for the background compaction.

Twice the flush policy's compaction threshold of four.
"""


struct CompactionPolicy:
    """Bound level-zero segment growth with a deterministic threshold."""

    var max_level_zero_segments: Int

    def __init__(out self, max_level_zero_segments: Int) raises:
        if max_level_zero_segments <= 0:
            raise Error("compaction threshold must be positive")
        self.max_level_zero_segments = max_level_zero_segments

    def level_zero_count(self, manifest: Manifest) -> Int:
        var count = 0
        for index in range(len(manifest.segments)):
            if manifest.segments[index].level == 0:
                count += 1
        return count

    def should_compact(self, manifest: Manifest) -> Bool:
        return self.level_zero_count(manifest) >= self.max_level_zero_segments


def select_merge_range(sizes: List[UInt64]) raises -> Tuple[Int, Int]:
    """Choose a contiguous run; sizes are oldest first, with the base at zero.

    Bound space amplification at 200% of the base (RocksDB universal style).
    Otherwise accumulate similar-sized newer runs with 1% slack. Merge at least
    four deltas, matching the automatic trigger and reducing run count by three.
    Smaller batches increased publication frequency and query tails in mixed
    workloads. If sizes prohibit four compatible runs, choose the cheapest
    adjacent four. An explicit compact bypasses this automatic policy.
    """
    if len(sizes) < 5:
        return (0, len(sizes))
    var total = UInt64(0)
    for size in sizes:
        if size > UInt64(Int.MAX) - total:
            raise Error("compaction input size exceeds implementation limit")
        total += size
    var tail = total - sizes[0]
    if tail // 2 >= sizes[0]:
        return (0, len(sizes))
    # Input manifests are ordered oldest first; examine newest runs first.
    var end = len(sizes)
    while end > 4:
        var start = end - 1
        var accumulated = sizes[start]
        while start > 1 and sizes[start - 1] <= accumulated + accumulated // 100:
            start -= 1
            accumulated += sizes[start]
        if end - start >= 4:
            return (start, end)
        end -= 1
    var best = 1
    var best_size = sizes[1] + sizes[2] + sizes[3] + sizes[4]
    for start in range(2, len(sizes) - 3):
        var size = sizes[start] + sizes[start + 1] + sizes[start + 2] + sizes[start + 3]
        if size < best_size:
            best = start
            best_size = size
    return (best, best + 4)


def select_point_merge_range(
    directory: String, manifest: Manifest
) raises -> Tuple[Int, Int]:
    """Stat leased inputs outside writer; record decoding stays in the builder."""
    if manifest.segments[0].level == 0:
        return (0, len(manifest.segments))
    var sizes = List[UInt64](capacity=len(manifest.segments))
    for index in range(len(manifest.segments)):
        with open(directory + "/" + manifest.segments[index].name, "r") as file:
            var size = file.seek(0, SEEK_END)
            if size < 52:
                raise Error("truncated point compaction input")
            sizes.append(size)
    return select_merge_range(sizes)
