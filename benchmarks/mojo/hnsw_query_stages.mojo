"""Diagnose a persisted graph using raw little-endian F32 query rows."""

from akasha import PersistentCollection
from akasha.storage.checksum import BorrowedBinaryReader
from akasha.storage.collection_config import load_collection_config
from akasha.storage.filesystem import read_file_bytes
from std.sys.arg import argv
from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("usage: hnsw-query-stages DATABASE QUERIES.f32 EF")
    var config = load_collection_config(args[1])
    var ef = Int(args[3])
    var bytes = read_file_bytes(args[2])
    if len(bytes) == 0 or len(bytes) % (config.dimension * 4) != 0:
        raise Error("queries must contain complete F32 vectors")
    var reader = BorrowedBinaryReader(Span(bytes))
    var queries = List[List[Float32]]()
    for _ in range(len(bytes) // (config.dimension * 4)):
        var query = List[Float32]()
        for _ in range(config.dimension):
            query.append(reader.read_f32())
        queries.append(query^)
    var collection = PersistentCollection.open_with_config(
        args[1], config, maintenance_library_path=""
    )
    assert_true(collection._ensure_hnsw_id_lookup())
    for sample in range(4):
        var collect_ns = 0
        var rerank_ns = 0
        var public_ns = 0
        var candidates_total = 0
        var distances = 0
        for row in range(len(queries)):
            ref query = queries[row]
            var start = perf_counter_ns()
            var candidates = collection._hnsw._search_candidates(query, 10, ef)
            collect_ns += perf_counter_ns() - start
            candidates_total += len(candidates)
            distances += (
                collection._hnsw.last_search_stats().distance_evaluations
            )
            start = perf_counter_ns()
            var results = collection._hnsw._rerank(
                query,
                10,
                candidates^,
                collection._memtable,
                collection._hnsw_id_lookup.value(),
            )
            rerank_ns += perf_counter_ns() - start
            start = perf_counter_ns()
            var public = collection._search_approx_unlocked(
                query, 10, ef, Int(config.ann_metric.tag())
            )
            public_ns += perf_counter_ns() - start
            assert_equal(len(results), len(public))
            for i in range(len(public)):
                assert_equal(results[i].id, public[i].id)
                assert_equal(results[i].score, public[i].score)
        print(
            "sample="
            + String(sample)
            + " queries="
            + String(len(queries))
            + " candidates="
            + String(candidates_total)
            + " distances="
            + String(distances)
            + " collect_ns="
            + String(collect_ns)
            + " rerank_ns="
            + String(rerank_ns)
            + " public_ns="
            + String(public_ns)
        )
    collection.close()
