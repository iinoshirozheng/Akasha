from akasha import PersistentCollection, ReadSnapshot
from akasha.index.flat import FlatIndex, SearchResult
from akasha.index.quantization import PqIndex, Sq8Index
from akasha.index.sparse import SparseIndex
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable, MemTableEntry
from std.memory import ArcPointer
from std.time import perf_counter_ns


comptime _DIMENSION = 16
comptime _POINTS = 1_000
comptime _QUERIES = 20


def _vector(seed: Int) -> List[Float32]:
    var vector = List[Float32](capacity=_DIMENSION)
    for column in range(_DIMENSION):
        vector.append(
            Float32((seed * 37 + column * 19 + seed * column * 3) % 251)
            / 37.0
            + 0.01
        )
    return vector^


def _recall(exact: List[SearchResult], approximate: List[SearchResult]) -> Float64:
    var matches = 0
    for expected in exact:
        for actual in approximate:
            if expected.id == actual.id:
                matches += 1
                break
    return Float64(matches) / Float64(len(exact))


def _p95(var samples: List[Int]) -> Int:
    for index in range(1, len(samples)):
        var cursor = index
        while cursor > 0 and samples[cursor] < samples[cursor - 1]:
            samples.swap_elements(cursor, cursor - 1)
            cursor -= 1
    return samples[(len(samples) * 95 + 99) // 100 - 1]


def _quantization_benchmark() raises:
    var ids = List[Int](capacity=_POINTS)
    var vectors = List[List[Float32]](capacity=_POINTS)
    var exact = FlatIndex(_DIMENSION)
    for id in range(1, _POINTS + 1):
        ids.append(id)
        var vector = _vector(id)
        exact.add(id, vector.copy())
        vectors.append(vector^)

    var sq8_start = perf_counter_ns()
    var sq8 = Sq8Index.build(ids, vectors)
    var sq8_build = perf_counter_ns() - sq8_start
    var pq_start = perf_counter_ns()
    var pq = PqIndex.build(ids, vectors, 4, 16, iterations=8)
    var pq_build = perf_counter_ns() - pq_start
    var sq8_recall: Float64 = 0.0
    var pq_recall: Float64 = 0.0
    var sq8_samples = List[Int](capacity=_QUERIES)
    var pq_samples = List[Int](capacity=_QUERIES)
    var sq8_query_total = 0
    var pq_query_total = 0
    for query_index in range(_QUERIES):
        var query = _vector(10_000 + query_index)
        var oracle = exact.search_l2(query, 10)
        var start = perf_counter_ns()
        var sq8_result = sq8.search_l2(query, 10)
        var elapsed = perf_counter_ns() - start
        sq8_samples.append(elapsed)
        sq8_query_total += elapsed
        start = perf_counter_ns()
        var pq_result = pq.search_l2(query, 10)
        elapsed = perf_counter_ns() - start
        pq_samples.append(elapsed)
        pq_query_total += elapsed
        sq8_recall += _recall(oracle, sq8_result)
        pq_recall += _recall(oracle, pq_result)
    sq8_recall /= Float64(_QUERIES)
    pq_recall /= Float64(_QUERIES)
    if sq8_recall < 0.80:
        raise Error("Phase 12 SQ8 recall gate failed")
    if pq_recall < 0.70:
        raise Error("Phase 12 PQ recall gate failed")
    print(
        "phase12 SQ8 recall@10",
        sq8_recall,
        "qps",
        Float64(_QUERIES) * 1.0e9 / Float64(sq8_query_total),
        "p95 ns",
        _p95(sq8_samples^),
        "build ns",
        sq8_build,
        "estimated bytes",
        sq8.estimated_bytes(),
    )
    print(
        "phase12 PQ recall@10",
        pq_recall,
        "qps",
        Float64(_QUERIES) * 1.0e9 / Float64(pq_query_total),
        "p95 ns",
        _p95(pq_samples^),
        "build ns",
        pq_build,
        "estimated bytes",
        pq.estimated_bytes(),
    )


def _parallel_and_rerank_gate() raises:
    var entries = List[MemTableEntry](capacity=256)
    for id in range(1, 257):
        var vector = _vector(id)
        entries.append(MemTableEntry(id, UInt64(id), False, vector^))
    var memtable = MemTable(_DIMENSION)
    memtable.apply_recovered_entries(entries)
    var sparse = SparseIndex()
    var pins = ArcPointer(GenerationPinRegistry())
    var snapshot = ReadSnapshot.capture(
        _DIMENSION, 0, UInt64(256), memtable, sparse, pins
    )
    var query = _vector(50_000)
    var scalar_start = perf_counter_ns()
    var scalar = snapshot.search_l2(query, 10)
    var scalar_ns = perf_counter_ns() - scalar_start
    var parallel_start = perf_counter_ns()
    var parallel = snapshot.search_l2_parallel(query, 10)
    var parallel_ns = perf_counter_ns() - parallel_start
    var sq8 = snapshot.search_sq8_l2(query, 10, rerank_k=256)
    var pq = snapshot.search_pq_l2(
        query,
        10,
        subquantizers=4,
        centroids=16,
        rerank_k=256,
    )
    for index in range(10):
        if (
            scalar[index].id != parallel[index].id
            or scalar[index].id != sq8[index].id
            or scalar[index].id != pq[index].id
            or scalar[index].score != parallel[index].score
            or scalar[index].score != sq8[index].score
            or scalar[index].score != pq[index].score
        ):
            raise Error("Phase 12 scalar differential gate failed")
    print(
        "phase12 exact scalar ns",
        scalar_ns,
        "parallel ns",
        parallel_ns,
    )
    snapshot.close()


def _reset(path: String) raises:
    ensure_directory(path)
    for name in [
        "manifest.bin",
        "manifest.bin.tmp",
        "wal.bin",
        "wal.bin.tmp",
        "sparse.wal",
        "sparse.wal.tmp",
        "hnsw.cache",
        "hnsw.cache.tmp",
        "metadata.cache",
        "metadata.cache.tmp",
    ]:
        remove_file_if_exists(path + "/" + name)
    for sequence in range(128):
        remove_file_if_exists(
            path + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            path + "/sparse-base-" + String(sequence) + ".bin"
        )


def _reopen_benchmark() raises:
    var path = String("/tmp/akasha-phase12-reopen-bench")
    _reset(path)
    var collection = PersistentCollection.open(path, _DIMENSION)
    for id in range(1, 81):
        var vector = _vector(id)
        collection.upsert(id, vector^)
    _ = collection.search_l2_approx(_vector(99_999), 10, 80)
    collection.flush()
    collection.close()

    var warm_start = perf_counter_ns()
    var warm = PersistentCollection.open(path, _DIMENSION)
    var warm_result = warm.search_l2_approx(_vector(99_999), 10, 80)
    var warm_ns = perf_counter_ns() - warm_start
    if not warm.hnsw_cache_hit() or not warm.metadata_cache_hit():
        raise Error("Phase 12 warm reopen cache gate failed")
    if len(warm_result) != 10:
        raise Error("Phase 12 warm reopen query gate failed")
    warm.close()

    remove_file_if_exists(path + "/hnsw.cache")
    remove_file_if_exists(path + "/metadata.cache")
    var cold_start = perf_counter_ns()
    var cold = PersistentCollection.open(path, _DIMENSION)
    var cold_result = cold.search_l2_approx(_vector(99_999), 10, 80)
    var cold_ns = perf_counter_ns() - cold_start
    if cold.hnsw_cache_hit() or cold.metadata_cache_hit():
        raise Error("Phase 12 cold reopen cache gate failed")
    if cold_result[0].id != warm_result[0].id:
        raise Error("Phase 12 reopen result parity gate failed")
    print("phase12 warm reopen+query ns", warm_ns, "cold ns", cold_ns)
    cold.close()


def main() raises:
    _quantization_benchmark()
    _parallel_and_rerank_gate()
    _reopen_benchmark()
