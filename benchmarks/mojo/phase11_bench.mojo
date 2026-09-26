from akasha import (
    BatchMutation,
    CollectionConfig,
    DocumentField,
    PayloadValue,
    PersistentCollection,
    ReadSnapshot,
)
from akasha.index.sparse import SparseElement
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

    var capture_start = perf_counter_ns()
    var cache = ReadGenerationCache()
    var snapshot = ReadSnapshot(
        cache.acquire(
            CollectionConfig.defaults(_DIMENSION),
            0,
            UInt64(_POINT_COUNT),
            table,
            pins,
        )
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
    args.append(
        Python.import_module("builtins").str(
            Python.import_module("os").getpid()
        )
    )
    var output = Python.import_module("subprocess").check_output(args)
    return Int(py=Python.import_module("builtins").int(output)) * 1024


def _cost_upsert(
    mut table: MemTable,
    id: Int,
    sequence: UInt64,
    revision: Int,
    write_sparse: Bool = True,
) raises:
    var values = List[Float32](length=128, fill=Float32(revision))
    var fields = List[DocumentField]()
    fields.append(
        DocumentField("text", PayloadValue.string("p" * 255 + String(revision)))
    )
    table.apply_document_upsert(id, sequence, values^, fields^)
    if write_sparse:
        _cost_sparse(table, id, revision)


def _cost_sparse(mut table: MemTable, id: Int, revision: Int) raises:
    table.set_sparse(
        id,
        [
            SparseElement(0, Float32(revision + 1)),
            SparseElement(id + 1, Float32(revision + 1)),
        ],
    )


def _snapshot_cost_benchmark(
    delta: Int, leases: Int, write_sparse: Bool
) raises:
    comptime points = 4096
    if delta < 0 or delta > points or leases < 1 or leases > 16:
        raise Error("invalid snapshot cost dimensions")
    _ = _rss_bytes()
    var table = MemTable(128)
    for id in range(points):
        _cost_upsert(table, id, UInt64(2 * id + 1), 0)
    var sequence = UInt64(2 * points)
    # One dense and one optional sparse operation per changed point.
    var step = UInt64(2 if write_sparse else 1)
    var pins = ArcPointer(GenerationPinRegistry())
    var cache = ReadGenerationCache()
    var snapshots = List[ReadSnapshot](capacity=leases)
    var config = CollectionConfig.defaults(128)
    var baseline_rss = _rss_bytes()
    var elapsed = 0
    for capture in range(leases):
        # Writer side: every accepted operation goes through the publisher,
        # exactly as PersistentCollection does after its WAL commit.
        var record_ns = 0
        var max_record_ns = 0
        var rollover_ns = 0
        var consolidation_ns = 0
        var written = cache.stats.copy()
        for id in range(delta):
            # Each operation is recorded on its own, as the collection does.
            for operation in range(Int(step)):
                if operation == 0:
                    _cost_upsert(table, id, sequence + 1, capture + 1, False)
                else:
                    _cost_sparse(table, id, capture + 1)
                sequence += 1
                var before = cache.stats.copy()
                var record_start = perf_counter_ns()
                cache.record(table, [id], sequence)
                var record_duration = Int(perf_counter_ns() - record_start)
                record_ns += record_duration
                max_record_ns = max(max_record_ns, record_duration)
                if cache.stats.rollovers != before.rollovers:
                    rollover_ns += record_duration
                if cache.merge_due():
                    # The collection's worker merges off the writer path.
                    var merge_start = perf_counter_ns()
                    cache.merge_sealed_runs()
                    consolidation_ns += Int(perf_counter_ns() - merge_start)
        print(
            "publisher_write delta="
            + String(delta)
            + " leases="
            + String(leases)
            + " sparse_writes="
            + String(Int(write_sparse))
            + " capture="
            + String(capture)
            + " record_total_ns="
            + String(record_ns)
            + " max_record_ns="
            + String(max_record_ns)
            + " rollovers="
            + String(cache.stats.rollovers - written.rollovers)
            + " rollover_ns="
            + String(rollover_ns)
            + " consolidations="
            + String(cache.stats.consolidations - written.consolidations)
            + " consolidation_ns="
            + String(consolidation_ns)
            + " sealed_runs="
            + String(cache.sealed_count())
            + " head_points="
            + String(cache.head_count())
            + " descriptor_copies="
            + String(cache.stats.descriptor_copies - written.descriptor_copies)
            + " payload_copy_bytes="
            + String(cache.stats.payload_bytes - written.payload_bytes)
            + " sparse_copy_bytes="
            + String(cache.stats.sparse_bytes - written.sparse_bytes)
            + " base_builds="
            + String(cache.stats.base_builds - written.base_builds)
        )
        var before = cache.stats.copy()
        var start = perf_counter_ns()
        var root = cache.acquire(config, 7, sequence, table, pins)
        var duration = Int(perf_counter_ns() - start)
        elapsed += duration
        # Same publisher used by PersistentCollection, excluding manifest I/O
        # and lock acquisition. Dense bytes are audited by owner identity:
        # a visible row whose Float32 buffer is not the writer's accepted
        # owner would be a copy; payload and sparse owners are audited the
        # same way. Payload and sparse bytes are logical content copied into
        # run indexes; index structure, padding and allocator metadata remain
        # excluded.
        var dense_copy_bytes = 0
        var field_owner_copies = 0
        for location in root[].id_ordered_locations():
            ref entry = (
                root[].run(location[0]).memtable.entry_ref_at(location[1])
            )
            ref live = table.entry_ref_at(table.ordinal_for(entry.id))
            if entry.dense_address() != live.dense_address():
                dense_copy_bytes += entry.dense_bytes()
            if (
                entry.payload_address() != live.payload_address()
                or entry.sparse_address() != live.sparse_address()
            ):
                field_owner_copies += 1
        print(
            "snapshot_capture delta="
            + String(delta)
            + " leases="
            + String(leases)
            + " sparse_writes="
            + String(Int(write_sparse))
            + " capture="
            + String(capture)
            + " generation=7 sequence="
            + String(sequence)
            + " capture_ns="
            + String(duration)
            + " base_builds="
            + String(cache.stats.base_builds - before.base_builds)
            + " dense_copy_bytes="
            + String(dense_copy_bytes)
            + " field_owner_copies="
            + String(field_owner_copies)
            + " descriptor_copies="
            + String(cache.stats.descriptor_copies - before.descriptor_copies)
            + " payload_copy_bytes="
            + String(cache.stats.payload_bytes - before.payload_bytes)
            + " sparse_copy_bytes="
            + String(cache.stats.sparse_bytes - before.sparse_bytes)
            + " layers="
            + String(root[].layer_count())
            + " root_revision="
            + String(cache.revision)
        )
        snapshots.append(ReadSnapshot(root^))
    var held_rss = _rss_bytes()
    for capture in range(leases):
        var expected = Float32(capture + 1 if delta > 0 else 0)
        var document = snapshots[capture].get(0)
        if (
            snapshots[capture].generation() != 7
            or document.value().vector[0] != expected
        ):
            raise Error("snapshot cost visibility mismatch")
        if snapshots[capture].last_sequence() != UInt64(
            2 * points
        ) + step * UInt64(delta * (capture + 1)):
            raise Error("snapshot cost sequence mismatch")
        if document.value().get_field(
            "text"
        ).value().as_string() != "p" * 255 + String(Int(expected)):
            raise Error("snapshot cost payload mismatch")
        var sparse_hit = snapshots[capture].search_sparse_dot(
            [SparseElement(1, 1.0)], 1
        )
        var sparse_expected = expected + 1.0 if write_sparse else Float32(1.0)
        if (
            len(sparse_hit) != 1
            or sparse_hit[0].id != 0
            or sparse_hit[0].score != sparse_expected
        ):
            raise Error("snapshot cost sparse mismatch")
        if len(snapshots[capture].documents()) != points:
            raise Error("snapshot cost visible count mismatch")
        snapshots[capture].close()
    var closed_rss = _rss_bytes()
    snapshots.clear()
    cache.reset()
    if pins[].active_count() != 0:
        raise Error("snapshot cost pin leak")
    var dropped_rss = _rss_bytes()
    print(
        "snapshot_memory delta="
        + String(delta)
        + " leases="
        + String(leases)
        + " sparse_writes="
        + String(Int(write_sparse))
        + " capture_total_ns="
        + String(elapsed)
        + " baseline_rss="
        + String(baseline_rss)
        + " held_rss="
        + String(held_rss)
        + " closed_rss="
        + String(closed_rss)
        + " dropped_rss="
        + String(dropped_rss)
    )


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
    if len(args) == 5 and args[1] == "--snapshot-cost":
        _snapshot_cost_benchmark(
            Int(args[2]), Int(args[3]), args[4] == "dense-sparse"
        )
        return
    _snapshot_benchmark()
    _concurrency_benchmark()
    _maintenance_benchmark()
    for write_sparse in [True, False]:
        for delta in [0, 16, 1024]:
            for leases in [1, 8]:
                _snapshot_cost_benchmark(delta, leases, write_sparse)
        # Nine 1,024-point captures reach MAX_SEALED_RUNS and merge.
        _snapshot_cost_benchmark(1024, 10, write_sparse)
