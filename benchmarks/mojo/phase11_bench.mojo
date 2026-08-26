from akasha import BatchMutation, PersistentCollection, ReadSnapshot
from akasha.index.sparse import SparseIndex
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.manifest import load_manifest
from akasha.storage.memtable import MemTable, MemTableEntry
from max.algorithm import parallelize
from std.atomic import Atomic
from std.memory import ArcPointer
from std.time import perf_counter_ns


comptime _DIMENSION = 16
comptime _POINT_COUNT = 10_000


def _vector(seed: Int) -> List[Float32]:
    var values = List[Float32](capacity=_DIMENSION)
    for index in range(_DIMENSION):
        values.append(Float32((seed * 11 + index * 5) % 43 - 21) + 0.25)
    return values^


def _snapshot_benchmark() raises:
    var entries = List[MemTableEntry](capacity=_POINT_COUNT)
    for point_id in range(_POINT_COUNT):
        var values = _vector(point_id)
        entries.append(
            MemTableEntry(point_id, UInt64(point_id + 1), False, values^)
        )
    var table = MemTable(_DIMENSION)
    table.apply_recovered_entries(entries)
    var pins = ArcPointer(GenerationPinRegistry())
    var sparse = SparseIndex()

    var capture_start = perf_counter_ns()
    var snapshot = ReadSnapshot.capture(
        _DIMENSION,
        0,
        UInt64(_POINT_COUNT),
        table,
        sparse,
        pins,
    )
    var capture_elapsed = perf_counter_ns() - capture_start
    var query = _vector(100_000)
    var search_start = perf_counter_ns()
    var results = snapshot.search_dot(query, 10)
    var search_elapsed = perf_counter_ns() - search_start
    if len(results) != 10 or snapshot.last_sequence() != UInt64(_POINT_COUNT):
        raise Error("snapshot benchmark correctness failure")
    print(
        "phase11 snapshot points",
        _POINT_COUNT,
        "capture ns/point",
        Float64(capture_elapsed) / Float64(_POINT_COUNT),
        "exact search ns",
        search_elapsed,
    )
    snapshot.close()


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/sparse.wal")
    remove_file_if_exists(directory + "/sparse.wal.tmp")
    for sequence in range(128):
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-delta-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-delta-" + String(sequence) + ".bin"
        )


def _concurrency_benchmark() raises:
    var path = String("/tmp/akasha-phase11-concurrency-bench")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var failures = Atomic[DType.int64](0)
    var start = perf_counter_ns()

    def write_batch(worker: Int) {mut collection, mut failures}:
        try:
            var mutations = List[BatchMutation]()
            for offset in range(8):
                var id = worker * 100 + offset
                mutations.append(BatchMutation.upsert(id, [Float32(id + 1)]))
            _ = collection.apply_batch(mutations)
        except:
            _ = failures.fetch_add(1)

    parallelize(write_batch, 8, 4)
    var elapsed = perf_counter_ns() - start
    if failures.load() != 0 or collection.last_sequence() != UInt64(64):
        raise Error("concurrent writer benchmark correctness failure")
    print(
        "phase11 concurrent atomic mutations",
        64,
        "ns/mutation",
        Float64(elapsed) / 64.0,
    )
    collection.close()


def _maintenance_benchmark() raises:
    var path = String("/tmp/akasha-phase11-maintenance-bench")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    for id in range(2, 5):
        collection.upsert(id, [Float32(id)])
        collection.flush()
    collection.upsert(5, [5.0])
    var trigger_start = perf_counter_ns()
    collection.flush()
    var foreground_elapsed = perf_counter_ns() - trigger_start
    var wait_start = perf_counter_ns()
    _ = collection.wait_for_maintenance()
    var wait_elapsed = perf_counter_ns() - wait_start
    var manifest = load_manifest(path, 1)
    if len(manifest.segments) != 1 or manifest.last_sequence != UInt64(5):
        raise Error("background maintenance benchmark correctness failure")
    print(
        "phase11 background maintenance foreground ns",
        foreground_elapsed,
        "drain ns",
        wait_elapsed,
    )
    collection.close()


def main() raises:
    _snapshot_benchmark()
    _concurrency_benchmark()
    _maintenance_benchmark()
