from akasha.common.config import CollectionConfig
from akasha.index.hnsw import HnswIndex
from akasha.index.segmented_hnsw import SegmentedHnsw
from akasha.storage.hnsw_store import (
    HnswOpenStats,
    open_hnsw_snapshot_view_with_stats,
    write_hnsw_snapshot,
)
from std.sys.arg import argv
from std.time import perf_counter_ns


def main() raises:
    var args = argv()
    if len(args) != 6:
        raise Error(
            "usage: mmap-bench prepare|open PATH POINTS DIMENSION REPETITIONS"
        )
    var count = Int(args[3])
    var dimension = Int(args[4])
    var config = CollectionConfig.defaults(dimension)
    config.m = 16
    config.m0 = 32
    if args[1] == "prepare":
        var index = HnswIndex(config)
        for slot in range(count):
            var vector = List[Float32]()
            for column in range(dimension):
                vector.append(
                    Float32((slot * 13 + column * 7) % 29 - 14) / 16.0
                )
            _ = index.graph.append(count - slot, vector^, 0)
        index.entry_slot = Optional(UInt32(0))
        index.entry_level = 0
        index.build_stats.slot_count = count
        index.build_stats.maximum_level = 0
        # Valid symmetric level-0 ring, degree 32. Measures storage validation,
        # not ANN construction quality, with realistic vector/edge volume.
        for slot in range(count):
            for delta in range(1, 17):
                _ = index.graph.add_neighbor(
                    UInt32(slot), 0, UInt32((slot + delta) % count)
                )
                _ = index.graph.add_neighbor(
                    UInt32(slot), 0, UInt32((slot - delta + count) % count)
                )
        _ = write_hnsw_snapshot(args[2], index, UInt64(count))
        return
    for repetition in range(Int(args[5])):
        var stats = HnswOpenStats()
        var start = perf_counter_ns()
        var view = open_hnsw_snapshot_view_with_stats(
            args[2], config, UInt64(count), stats
        )
        var validate_ns = perf_counter_ns() - start
        start = perf_counter_ns()
        var segmented = SegmentedHnsw.from_mapped(view^)
        print(
            "open sample="
            + String(repetition)
            + " mapping_ns="
            + String(stats.mapping_ns)
            + " checksum_ns="
            + String(stats.checksum_ns)
            + " layout_ns="
            + String(stats.layout_ns)
            + " validation_ns="
            + String(stats.validation_ns)
            + " source_map_ns="
            + String(perf_counter_ns() - start)
            + " open_validate_ns="
            + String(validate_ns)
            + " level_cells="
            + String(stats.validation.owned_level_cells)
            + " edge_entries="
            + String(stats.validation.directed_edges)
            + " auxiliary_reserved_bytes="
            + String(stats.validation.auxiliary_reserved_bytes)
        )
        segmented.close()
