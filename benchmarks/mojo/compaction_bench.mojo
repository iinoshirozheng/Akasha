from akasha import PersistentCollection
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import (
    ensure_directory,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import (
    Manifest,
    publish_manifest,
    SegmentDescriptor,
)
from akasha.storage.memtable import MemTableEntry
from akasha.storage.segment import (
    encode_segment_v3,
    SEGMENT_KIND_BASE,
    SEGMENT_KIND_DELTA,
)
from std.time import perf_counter_ns


comptime _DIMENSION = 4
comptime _DELTA_PERCENT = 1


def _vector(seed: Int) -> List[Float32]:
    return [
        Float32(seed % 97),
        Float32(seed % 89),
        Float32(seed % 83),
        Float32(seed % 79),
    ]


def _base_entries(point_count: Int) -> List[MemTableEntry]:
    var entries = List[MemTableEntry](capacity=point_count)
    for point_id in range(point_count):
        var values = _vector(point_id)
        entries.append(
            MemTableEntry(
                point_id,
                UInt64(point_id + 1),
                False,
                values^,
            )
        )
    return entries^


def _delta_entries(point_count: Int) -> List[MemTableEntry]:
    var delta_count = max(1, point_count * _DELTA_PERCENT // 100)
    var entries = List[MemTableEntry](capacity=delta_count)
    for delta_index in range(delta_count):
        var point_id = delta_index * 100
        var values = _vector(point_id + point_count)
        entries.append(
            MemTableEntry(
                point_id,
                UInt64(point_count + delta_index + 1),
                False,
                values^,
            )
        )
    return entries^


def _compacted_entries(point_count: Int) -> List[MemTableEntry]:
    var entries = List[MemTableEntry](capacity=point_count)
    for point_id in range(point_count):
        var sequence = UInt64(point_id + 1)
        var vector_seed = point_id
        if point_id % 100 == 0:
            sequence = UInt64(point_count + point_id // 100 + 1)
            vector_seed += point_count
        var values = _vector(vector_seed)
        entries.append(MemTableEntry(point_id, sequence, False, values^))
    return entries^


def _benchmark(point_count: Int) raises -> Float64:
    var directory = "/tmp/akasha-phase10-compaction-bench-" + String(
        point_count
    )
    var base_name = String("segment-base-bench.bin")
    var delta_name = String("segment-delta-bench.bin")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/sparse.wal")
    remove_file_if_exists(directory + "/sparse.wal.tmp")
    remove_file_if_exists(directory + "/" + base_name)
    remove_file_if_exists(directory + "/" + delta_name)

    var base_entries = _base_entries(point_count)
    var base_encode_start = perf_counter_ns()
    var base_bytes = encode_segment_v3(
        _DIMENSION,
        SEGMENT_KIND_BASE,
        0,
        UInt64(point_count),
        base_entries,
    )
    var base_encode_elapsed = perf_counter_ns() - base_encode_start
    var base_size = len(base_bytes)

    var delta_entries = _delta_entries(point_count)
    var delta_count = len(delta_entries)
    var delta_encode_start = perf_counter_ns()
    var delta_bytes = encode_segment_v3(
        _DIMENSION,
        SEGMENT_KIND_DELTA,
        UInt64(point_count + 1),
        UInt64(point_count + delta_count),
        delta_entries,
    )
    var delta_encode_elapsed = perf_counter_ns() - delta_encode_start
    var delta_size = len(delta_bytes)

    write_file_sync(directory + "/" + base_name, base_bytes)
    write_file_sync(directory + "/" + delta_name, delta_bytes)
    var descriptors = List[SegmentDescriptor]()
    descriptors.append(
        SegmentDescriptor(
            1,
            0,
            UInt64(point_count),
            crc32_range(base_bytes, 4, len(base_bytes) - 4),
            base_name,
        )
    )
    descriptors.append(
        SegmentDescriptor(
            0,
            UInt64(point_count + 1),
            UInt64(point_count + delta_count),
            crc32_range(delta_bytes, 4, len(delta_bytes) - 4),
            delta_name,
        )
    )
    var manifest = Manifest.with_segments(
        _DIMENSION,
        2,
        UInt64(point_count + delta_count),
        descriptors^,
    )
    publish_manifest(directory, manifest^)

    var reopen_start = perf_counter_ns()
    var collection = PersistentCollection.open(directory, _DIMENSION)
    var reopen_elapsed = perf_counter_ns() - reopen_start
    if (
        collection.last_sequence() != UInt64(point_count + delta_count)
        or not Bool(collection.get(0))
        or not Bool(collection.get(point_count - 1))
    ):
        raise Error("collection reopen state mismatch")
    collection.close()

    var compacted_entries = _compacted_entries(point_count)
    var compact_start = perf_counter_ns()
    var compacted_bytes = encode_segment_v3(
        _DIMENSION,
        SEGMENT_KIND_BASE,
        0,
        UInt64(point_count + delta_count),
        compacted_entries,
    )
    var compact_elapsed = perf_counter_ns() - compact_start

    var amplification = Float64(delta_size) / Float64(base_size)
    print(
        "storage points",
        point_count,
        "base bytes",
        base_size,
        "delta bytes",
        delta_size,
        "delta/base",
        amplification,
        "base encode ns/point",
        Float64(base_encode_elapsed) / Float64(point_count),
        "delta encode ns/point",
        Float64(delta_encode_elapsed) / Float64(delta_count),
        "reopen ns/record",
        Float64(reopen_elapsed) / Float64(point_count + delta_count),
        "compact ns/point",
        Float64(compact_elapsed) / Float64(point_count),
        "compacted bytes",
        len(compacted_bytes),
    )
    if amplification >= 0.05:
        raise Error("incremental write amplification regressed")
    return Float64(reopen_elapsed) / Float64(point_count + delta_count)


def main() raises:
    var small_recovery = _benchmark(10_000)
    var large_recovery = _benchmark(100_000)
    if large_recovery > small_recovery * 8.0:
        raise Error("segment recovery scaling regressed")
