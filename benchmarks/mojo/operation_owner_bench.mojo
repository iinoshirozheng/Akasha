"""Per-operation cost of collection and snapshot queries (#50).

Prints one `name=median_us` line per case: the median over rounds of the mean
microseconds per call. Uses only public API, so it runs on older revisions too.
"""

from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    SparseElement,
)
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.sys.arg import argv
from std.time import perf_counter_ns

comptime POINTS = 4096
comptime DIMENSION = 128
comptime ROUNDS = 7


def _vector(id: Int) -> List[Float32]:
    var values = List[Float32](capacity=DIMENSION)
    for index in range(DIMENSION):
        values.append(Float32((id * 31 + index * 7) % 97) / 97.0)
    return values^


def _fields(id: Int) raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("keep", PayloadValue.boolean(id % 2 == 0)))
    return fields^


def _since(start: Int, calls: Int) -> Float64:
    return Float64(perf_counter_ns() - start) / 1000.0 / Float64(calls)


def _median(var samples: List[Float64]) -> Float64:
    for i in range(len(samples)):
        for j in range(i + 1, len(samples)):
            if samples[j] < samples[i]:
                var swap = samples[i]
                samples[i] = samples[j]
                samples[j] = swap
    return samples[len(samples) // 2]


def _report(name: String, var samples: List[Float64]):
    print(name + "=" + String(_median(samples^)))


def _measure_reads(label: String, mut collection: PersistentCollection) raises:
    """Report read cases on the collection's current root, `label` first."""
    var query = _vector(POINTS + 1)
    var sparse: List[SparseElement] = [SparseElement(3, 1.0)]
    var keep = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    var queries = List[List[Float32]]()
    queries.append(query.copy())
    var options = GpuExecutionOptions(enabled=True, min_work_items=1)
    var snapshot = collection.snapshot()
    var calls = 200
    var checksum = 0
    var collection_dot = List[Float64]()
    var collection_where = List[Float64]()
    var collection_sparse = List[Float64]()
    var snapshot_dot = List[Float64]()
    var snapshot_where = List[Float64]()
    var snapshot_sparse = List[Float64]()
    var capture = List[Float64]()
    var device = List[Float64]()
    for _ in range(ROUNDS):
        var start = perf_counter_ns()
        for _ in range(calls):
            checksum += collection.search_dot(query, 10)[0].id
        collection_dot.append(_since(start, calls))
        start = perf_counter_ns()
        for _ in range(calls):
            checksum += collection.search_dot_where(query, 10, keep)[0].id
        collection_where.append(_since(start, calls))
        start = perf_counter_ns()
        for _ in range(calls):
            checksum += collection.search_sparse_dot(sparse, 10)[0].id
        collection_sparse.append(_since(start, calls))
        start = perf_counter_ns()
        for _ in range(calls):
            checksum += snapshot.search_dot(query, 10)[0].id
        snapshot_dot.append(_since(start, calls))
        start = perf_counter_ns()
        for _ in range(calls):
            checksum += snapshot.search_dot_where(query, 10, keep)[0].id
        snapshot_where.append(_since(start, calls))
        start = perf_counter_ns()
        for _ in range(calls):
            checksum += snapshot.search_sparse_dot(sparse, 10)[0].id
        snapshot_sparse.append(_since(start, calls))
        start = perf_counter_ns()
        for _ in range(calls):
            var captured = collection.snapshot()
            checksum += Int(captured.last_sequence())
            captured.close()
        capture.append(_since(start, calls))
        start = perf_counter_ns()
        for _ in range(calls):
            var result = collection.search_device_dot_batch[True](
                queries, 10, options
            )
            checksum += result.results[0][0].id
        device.append(_since(start, calls))
    _report(label + "collection_search_dot_us", collection_dot^)
    _report(label + "collection_search_dot_where_us", collection_where^)
    _report(label + "collection_search_sparse_dot_us", collection_sparse^)
    _report(label + "snapshot_search_dot_us", snapshot_dot^)
    _report(label + "snapshot_search_dot_where_us", snapshot_where^)
    _report(label + "snapshot_search_sparse_dot_us", snapshot_sparse^)
    _report(label + "collection_snapshot_close_us", capture^)
    _report(label + "collection_device_dot_batch_warm_us", device^)
    print(label + "checksum=" + String(checksum))
    snapshot.close()


def main() raises:
    var path = String("/tmp/akasha-operation-owner-bench")
    var args = argv()
    if len(args) > 1:
        path = String(args[1])
    ensure_directory(path)
    for name in ["manifest.bin", "wal.bin", "sparse.wal"]:
        remove_file_if_exists(path + "/" + name)
    var collection = PersistentCollection.open(path, DIMENSION)
    for id in range(POINTS):
        collection.upsert_document(id, _vector(id), _fields(id))
        collection.upsert_sparse(id, [SparseElement(id % 64, 1.0)])
    collection.flush()
    _measure_reads("base_", collection)
    # Alternate writes and queries, leaving sealed runs and a head behind.
    var query = _vector(POINTS + 1)
    var calls = 200
    var checksum = 0
    var write_then_query = List[Float64]()
    for round in range(ROUNDS):
        var start = perf_counter_ns()
        for call in range(calls):
            var id = (round * calls + call) % POINTS
            collection.upsert_document(id, _vector(id), _fields(id))
            checksum += collection.search_dot(query, 10)[0].id
        write_then_query.append(_since(start, calls))
    _report("upsert_then_collection_search_dot_us", write_then_query^)
    print("checksum=" + String(checksum))
    _measure_reads("layered_", collection)
    collection.close()
