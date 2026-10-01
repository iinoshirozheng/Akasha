"""Root PQ cold build and warm query, with untimed oracle checks (#55)."""

from akasha import ReadSnapshot
from akasha.common.config import CollectionConfig
from akasha.index.flat import SearchResult
from akasha.index.quantization import PqIndex
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable, MemTableEntry
from akasha.storage.read_generation import ReadGenerationCache
from std.memory import ArcPointer
from std.time import perf_counter_ns

comptime POINTS = 1024
comptime DIMENSION = 32
comptime ROUNDS = 7
comptime QUERIES = 64


def _vector(id: Int) -> List[Float32]:
    var values = List[Float32](capacity=DIMENSION)
    for column in range(DIMENSION):
        values.append(Float32((id * 31 + column * 7) % 97) / 97.0 + 0.01)
    return values^


def _same(expected: List[SearchResult], actual: List[SearchResult]) raises:
    if len(expected) != len(actual):
        raise Error("PQ artifact benchmark result count mismatch")
    for rank in range(len(expected)):
        if (
            expected[rank].id != actual[rank].id
            or expected[rank].score != actual[rank].score
        ):
            raise Error("PQ artifact benchmark oracle mismatch")


def main() raises:
    var entries = List[MemTableEntry](capacity=POINTS)
    var ids = List[Int](capacity=POINTS)
    var vectors = List[List[Float32]](capacity=POINTS)
    for id in range(POINTS):
        var vector = _vector(id)
        ids.append(id)
        vectors.append(vector.copy())
        entries.append(MemTableEntry(id, UInt64(id + 1), False, vector^))
    var table = MemTable(DIMENSION)
    table.apply_recovered_entries(entries)
    var query = _vector(POINTS + 1)
    var configs: List[Tuple[Int, Int, Int]] = [(4, 16, 8), (8, 16, 4)]
    print(
        "subquantizers,centroids,iterations,round,cold_build_ns,warm_query_mean_ns,build_count,artifact_bytes"
    )
    for config in configs:
        var oracle = PqIndex.build(
            ids, vectors, config[0], config[1], iterations=config[2]
        )
        var expected = oracle.search_l2(query, 10)
        for round in range(ROUNDS):
            var pins = ArcPointer(GenerationPinRegistry())
            var cache = ReadGenerationCache()
            var snapshot = ReadSnapshot(
                cache.acquire(
                    CollectionConfig.defaults(DIMENSION),
                    0,
                    UInt64(POINTS),
                    table,
                    pins,
                )
            )
            var root = snapshot._acquire()
            var start = perf_counter_ns()
            var artifact = snapshot._pq_artifact(
                root[], config[0], config[1], config[2], None
            )
            var cold = perf_counter_ns() - start
            _same(expected, artifact[].search_l2(query, 10))
            # Warm the public route, then time individual calls. Checks are untimed.
            _same(
                expected,
                snapshot.search_pq_l2(
                    query,
                    10,
                    subquantizers=config[0],
                    centroids=config[1],
                    iterations=config[2],
                ),
            )
            var elapsed = 0
            for _ in range(QUERIES):
                start = perf_counter_ns()
                var actual = snapshot.search_pq_l2(
                    query,
                    10,
                    subquantizers=config[0],
                    centroids=config[1],
                    iterations=config[2],
                )
                elapsed += perf_counter_ns() - start
                _same(expected, actual)
            var state = root[].pq[].get(config[0], config[1], config[2])
            if state[].build_count != 1:
                raise Error("warm PQ query rebuilt the artifact")
            print(
                String(config[0])
                + ","
                + String(config[1])
                + ","
                + String(config[2])
                + ","
                + String(round)
                + ","
                + String(cold)
                + ","
                + String(Float64(elapsed) / QUERIES)
                + ","
                + String(state[].build_count)
                + ","
                + String(artifact[].estimated_bytes())
            )
