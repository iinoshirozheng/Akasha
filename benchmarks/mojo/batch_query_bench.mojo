from akasha import ReadSnapshot
from akasha.index.sparse import SparseIndex
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable, MemTableEntry
from std.memory import ArcPointer
from std.time import perf_counter_ns


comptime _DIMENSION = 32
comptime _POINT_COUNT = 10_000
comptime _K = 10


def _vector(seed: Int) -> List[Float32]:
    var values = List[Float32](capacity=_DIMENSION)
    for index in range(_DIMENSION):
        values.append(Float32((seed * 7 + index * 3) % 29 - 14) + 0.25)
    return values^


def _snapshot() raises -> ReadSnapshot:
    var entries = List[MemTableEntry](capacity=_POINT_COUNT)
    for point_id in range(_POINT_COUNT):
        var values = _vector(point_id)
        entries.append(
            MemTableEntry(
                point_id,
                UInt64(point_id + 1),
                False,
                values^,
            )
        )
    var table = MemTable(_DIMENSION)
    table.apply_recovered_entries(entries)
    var pins = ArcPointer(GenerationPinRegistry())
    var sparse = SparseIndex()
    return ReadSnapshot.capture(
        _DIMENSION, 0, UInt64(_POINT_COUNT), table, sparse, pins
    )


def _queries(count: Int) -> List[List[Float32]]:
    var queries = List[List[Float32]](capacity=count)
    for index in range(count):
        queries.append(_vector(index + 100_000))
    return queries^


def _benchmark(snapshot: ReadSnapshot, query_count: Int) raises:
    var queries = _queries(query_count)
    var oracle_ids = List[Int](capacity=query_count * _K)
    var sequential_start = perf_counter_ns()
    for index in range(query_count):
        var result = snapshot.search_dot(queries[index], _K)
        for item in result:
            oracle_ids.append(item.id)
    var sequential_elapsed = perf_counter_ns() - sequential_start

    var batch_start = perf_counter_ns()
    var batched = snapshot.search_dot_batch(queries, _K, num_workers=4)
    var batch_elapsed = perf_counter_ns() - batch_start
    var output_index = 0
    for query_results in batched:
        for item in query_results:
            if item.id != oracle_ids[output_index]:
                raise Error("batch benchmark result mismatch")
            output_index += 1

    print(
        "batch queries",
        query_count,
        "points",
        _POINT_COUNT,
        "sequential ns/query",
        Float64(sequential_elapsed) / Float64(query_count),
        "parallel ns/query",
        Float64(batch_elapsed) / Float64(query_count),
        "speedup",
        Float64(sequential_elapsed) / Float64(batch_elapsed),
    )


def main() raises:
    var snapshot = _snapshot()
    _benchmark(snapshot, 1)
    _benchmark(snapshot, 8)
    _benchmark(snapshot, 64)
    snapshot.close()
