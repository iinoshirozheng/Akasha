from akasha import BatchMutation, CollectionConfig, DocumentField, PayloadValue, PersistentCollection, ReadSnapshot
from akasha.index.sparse import SparseElement, SparseIndex
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.read_generation import ReadGenerationCache
from akasha.storage.manifest import load_manifest
from akasha.storage.memtable import MemTable, MemTableEntry
from max.algorithm import parallelize
from std.atomic import Atomic
from std.memory import ArcPointer
from std.python import Python
from std.sys.arg import argv
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
        CollectionConfig.defaults(_DIMENSION),
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


def _rss_bytes() raises -> Int:
    # RSS of this running Mojo process, outside capture timers. Python/runtime
    # imports are warmed before baseline; ps reports KiB on macOS and Linux.
    var args = Python.list()
    for arg in ["ps", "-o", "rss=", "-p"]:
        args.append(arg)
    args.append(Python.import_module("builtins").str(Python.import_module("os").getpid()))
    var output = Python.import_module("subprocess").check_output(args)
    return Int(py=Python.import_module("builtins").int(output)) * 1024


def _cost_upsert(mut table: MemTable, mut sparse: SparseIndex, id: Int, sequence: UInt64, revision: Int) raises:
    var values = List[Float32](length=128, fill=Float32(revision))
    var fields = List[DocumentField]()
    fields.append(DocumentField("text", PayloadValue.string("p" * 255 + String(revision))))
    table.apply_document_upsert(id, sequence, values^, fields^)
    sparse.upsert(id, [SparseElement(0, Float32(revision + 1)), SparseElement(id + 1, Float32(revision + 1))])


def _snapshot_cost_benchmark(delta: Int, leases: Int) raises:
    comptime points = 4096
    if delta < 0 or delta > points or leases < 1 or leases > 8:
        raise Error("invalid snapshot cost dimensions")
    _ = _rss_bytes()
    var table = MemTable(128)
    var sparse = SparseIndex()
    for id in range(points):
        _cost_upsert(table, sparse, id, UInt64(2 * id + 1), 0)
    var sequence = UInt64(2 * points)
    var pins = ArcPointer(GenerationPinRegistry())
    var cache = ReadGenerationCache()
    var snapshots = List[ReadSnapshot](capacity=leases)
    var config = CollectionConfig.defaults(128)
    var baseline_rss = _rss_bytes()
    var elapsed = 0
    for capture in range(leases):
        for id in range(delta):
            _cost_upsert(table, sparse, id, sequence + 1, capture + 1)
            sequence += 2  # one dense and one sparse accepted operation
        var previous_revision = cache.revision
        var start = perf_counter_ns()
        snapshots.append(ReadSnapshot(cache.acquire(config, 7, sequence, table, sparse, pins)))
        var duration = perf_counter_ns() - start
        elapsed += duration
        # Same publisher used by PersistentCollection, excluding manifest I/O
        # and lock acquisition. Count logical content only on a real base build;
        # index copies, padding and allocator metadata remain excluded.
        var built = cache.revision != previous_revision
        var logical_bytes = points * (128 * 4 + 256 + 2 * (8 + 4)) if built else 0
        print("snapshot_capture delta=" + String(delta) + " leases=" + String(leases) + " capture=" + String(capture) + " generation=7 sequence=" + String(sequence) + " capture_ns=" + String(duration) + " authoritative_copy_bytes=" + String(logical_bytes) + " root_revision=" + String(cache.revision) + " base_builds=" + String(Int(built)))
    var held_rss = _rss_bytes()
    for capture in range(leases):
        var expected = Float32(capture + 1 if delta > 0 else 0)
        var document = snapshots[capture].get(0)
        if snapshots[capture].generation() != 7 or document.value().vector[0] != expected:
            raise Error("snapshot cost visibility mismatch")
        if snapshots[capture].last_sequence() != UInt64(2 * points + 2 * delta * (capture + 1)):
            raise Error("snapshot cost sequence mismatch")
        if document.value().get_field("text").value().as_string() != "p" * 255 + String(Int(expected)):
            raise Error("snapshot cost payload mismatch")
        var sparse_hit = snapshots[capture].search_sparse_dot([SparseElement(1, 1.0)], 1)
        if len(sparse_hit) != 1 or sparse_hit[0].id != 0 or sparse_hit[0].score != expected + 1.0:
            raise Error("snapshot cost sparse mismatch")
        snapshots[capture].close()
    var closed_rss = _rss_bytes()
    snapshots.clear()
    cache.invalidate()
    if pins[].active_count() != 0:
        raise Error("snapshot cost pin leak")
    var dropped_rss = _rss_bytes()
    print("snapshot_memory delta=" + String(delta) + " leases=" + String(leases) + " capture_total_ns=" + String(elapsed) + " baseline_rss=" + String(baseline_rss) + " held_rss=" + String(held_rss) + " closed_rss=" + String(closed_rss) + " dropped_rss=" + String(dropped_rss))


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
    var args = argv()
    if len(args) == 4 and args[1] == "--snapshot-cost":
        _snapshot_cost_benchmark(Int(args[2]), Int(args[3]))
        return
    _snapshot_benchmark()
    _concurrency_benchmark()
    _maintenance_benchmark()
    for delta in [0, 16]:
        for leases in [1, 8]:
            _snapshot_cost_benchmark(delta, leases)
