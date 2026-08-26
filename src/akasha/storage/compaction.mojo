from akasha.storage.manifest import Manifest


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
