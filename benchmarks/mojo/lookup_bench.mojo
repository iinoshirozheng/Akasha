"""Fixed sparse/RRF lookup workloads. Compile before/after; exclude compilation."""

from akasha.index.sparse import SparseElement, SparseIndex
from akasha.index.flat import SearchResult
from akasha.query.fusion import reciprocal_rank_fusion
from std.sys.arg import argv
from std.time import perf_counter_ns


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("usage: lookup-bench sparse|fusion POINTS ITERATIONS")
    var count = Int(args[2])
    var iterations = Int(args[3])
    if count < 16 or iterations < 1:
        raise Error("invalid workload")
    var checksum = Float64(0)
    if args[1] == "sparse":
        var index = SparseIndex()
        var start = perf_counter_ns()
        for id in range(count):
            index.upsert(id, [SparseElement(0, 1.0), SparseElement(id + 1, 2.0)])
        var build_ns = perf_counter_ns() - start
        start = perf_counter_ns()
        for _ in range(iterations * 10):
            checksum += Float64(index.search_dot([SparseElement(count, 1.0)], 10)[0].id)
        var selective_ns = (perf_counter_ns() - start) // (iterations * 10)
        start = perf_counter_ns()
        for _ in range(iterations):
            var hits = index.search_dot([SparseElement(0, 1.0), SparseElement(count, 1.0)], 10)
            checksum += Float64(hits[0].score)
        var broad_ns = (perf_counter_ns() - start) // iterations
        start = perf_counter_ns()
        for id in range(0, count, 16):
            index.delete(id)
            index.upsert(id, [SparseElement(0, 1.0), SparseElement(id + 1, 2.0)])
        var mutation_ns = perf_counter_ns() - start
        start = perf_counter_ns()
        var cloned = index.clone()
        var clone_ns = perf_counter_ns() - start
        checksum += Float64(cloned.point_count())
        print("build_ns=" + String(build_ns) + " selective_ns=" + String(selective_ns) + " broad_ns=" + String(broad_ns) + " mutation_ns=" + String(mutation_ns) + " clone_ns=" + String(clone_ns) + " checksum=" + String(checksum))
    elif args[1] == "fusion":
        var dense = List[SearchResult](capacity=count)
        var sparse = List[SearchResult](capacity=count)
        for id in range(count):
            dense.append(SearchResult(id - count, 0.0))
            sparse.append(SearchResult(id - count // 2, 0.0))
        var start = perf_counter_ns()
        for _ in range(iterations):
            var hits = reciprocal_rank_fusion(dense, sparse, 10)
            checksum += Float64(hits[0].id) + Float64(hits[0].score)
        print("fusion_ns=" + String((perf_counter_ns() - start) // iterations) + " checksum=" + String(checksum))
    else:
        raise Error("unknown mode")
