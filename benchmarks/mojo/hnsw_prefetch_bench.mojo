"""Isolated immutable mapped-base prefetch experiment, no production changes."""

from akasha import PersistentCollection
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_core import (
    HnswSearchAdmission,
    greedy_descent,
    search_layer,
)
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.hnsw_storage import HnswGraphAccess
from akasha.index.hnsw_view import HnswGraphView
from akasha.storage.checksum import BorrowedBinaryReader
from akasha.storage.collection_config import load_collection_config
from akasha.storage.filesystem import read_file_bytes
from std.sys.arg import argv
from std.sys.intrinsics import prefetch
from std.testing import assert_equal
from std.time import perf_counter_ns


@fieldwise_init
struct Prefetched[origin: Origin, lines: Int](HnswGraphAccess):
    var graph: Pointer[HnswGraphView, Self.origin]

    def validate_search_ready(self) raises:
        self.graph[].validate_search_ready()

    def validate_structure(self) raises:
        self.graph[].validate_structure()

    def slot_count(self) -> Int:
        return self.graph[].slot_count()

    def graph_dimension(self) -> Int:
        return self.graph[].graph_dimension()

    def graph_m(self) -> Int:
        return self.graph[].graph_m()

    def graph_m0(self) -> Int:
        return self.graph[].graph_m0()

    def id_at(self, slot: UInt32) raises -> Int:
        return self.graph[].id_at(slot)

    def level(self, slot: UInt32) raises -> Int:
        return self.graph[].level(slot)

    def is_current(self, slot: UInt32) -> Bool:
        return self.graph[].is_current(slot)

    def distance_to_slot(
        self, dispatcher: MetricDispatcher, query: List[Float32], slot: UInt32
    ) raises -> Float32:
        return self.graph[].distance_to_slot(dispatcher, query, slot)

    def _distance_to_slot_backend[
        backend_tag: Int
    ](
        self, dispatcher: MetricDispatcher, query: List[Float32], slot: UInt32
    ) raises -> Float32:
        return self.graph[]._distance_to_slot_backend[backend_tag](
            dispatcher, query, slot
        )

    def neighbor_count(self, slot: UInt32, level: Int) raises -> Int:
        var count = self.graph[].neighbor_count(slot, level)
        comptime if Self.lines > 0:
            ref graph = self.graph[]
            for edge in range(count):
                var neighbor = graph.neighbor_at(slot, level, edge)
                _ = graph._slot_index(neighbor)
                var start = (
                    graph._vector_offset
                    + Int(neighbor) * graph._config.dimension * 4
                )
                var length = min(Self.lines * 128, graph._config.dimension * 4)
                _ = graph._mapping.checked_slice(UInt64(start), UInt64(length))
                for offset in range(0, length, 128):
                    prefetch(
                        graph._mapping._base.value().unsafe_offset(
                            start + offset
                        )
                    )
        return count

    def neighbor_at(
        self, slot: UInt32, level: Int, index: Int
    ) raises -> UInt32:
        return self.graph[].neighbor_at(slot, level, index)


def run[
    lines: Int, tag: Int
](
    ref graph: HnswGraphView,
    query: List[Float32],
    ef: Int,
    mut scratch: HnswSearchScratch,
) raises -> List[HnswHeapItem]:
    var metric = graph._metric.copy()
    var view = Prefetched[origin_of(graph), lines](Pointer(to=graph))
    var stats = HnswSearchStats()
    var current = graph._entry_slot.value()
    for level in range(graph._entry_level, 0, -1):
        current = greedy_descent[backend_tag=tag](
            view, metric, query, current, level, stats
        ).slot
    return search_layer[backend_tag=tag](
        view,
        metric,
        query,
        current,
        0,
        ef,
        ef,
        HnswSearchAdmission(),
        scratch,
        stats,
    )


def measure[
    lines: Int, tag: Int
](
    ref graph: HnswGraphView,
    queries: List[List[Float32]],
    ef: Int,
    expected: List[List[HnswHeapItem]],
    sample: Int,
) raises:
    var scratch = HnswSearchScratch()
    for query in queries:
        _ = run[lines, tag](graph, query, ef, scratch)
    var elapsed = 0
    for ordinal in range(len(queries)):
        var start = perf_counter_ns()
        var actual = run[lines, tag](graph, queries[ordinal], ef, scratch)
        elapsed += perf_counter_ns() - start
        assert_equal(len(actual), len(expected[ordinal]))
        for i in range(len(actual)):
            assert_equal(actual[i].id, expected[ordinal][i].id)
            assert_equal(actual[i].distance, expected[ordinal][i].distance)
    print("lines=", lines, "sample=", sample, "elapsed_ns=", elapsed)


def experiment[
    tag: Int
](ref graph: HnswGraphView, queries: List[List[Float32]], ef: Int) raises:
    var expected = List[List[HnswHeapItem]]()
    var scratch = HnswSearchScratch()
    for query in queries:
        expected.append(run[0, tag](graph, query, ef, scratch))
    for sample in range(7):
        if sample % 2 == 0:
            comptime for index in range(5):
                comptime lines = (0, 1, 2, 8, 48)[index]
                measure[lines, tag](graph, queries, ef, expected, sample)
        else:
            comptime for index in range(5):
                comptime lines = (48, 8, 2, 1, 0)[index]
                measure[lines, tag](graph, queries, ef, expected, sample)


def main() raises:
    var args = argv()
    if len(args) != 4:
        raise Error("usage: hnsw-prefetch DATABASE QUERIES.f32 EF")
    var config = load_collection_config(args[1])
    if config.scalar_kind.tag() != 0:
        raise Error("prototype requires F32 graph")
    var collection = PersistentCollection.open_with_config(
        args[1], config, maintenance_library_path=""
    )
    ref graph = collection._hnsw._mapped_base
    var bytes = read_file_bytes(args[2])
    var reader = BorrowedBinaryReader(Span(bytes))
    var queries = List[List[Float32]]()
    for _ in range(len(bytes) // (config.dimension * 4)):
        var query = List[Float32]()
        for _ in range(config.dimension):
            query.append(reader.read_f32())
        queries.append(graph._metric.prepare_query(query))
    if config.ann_metric.tag() == 0:
        experiment[0](graph, queries, Int(args[3]))
    elif config.ann_metric.tag() == 1:
        experiment[1](graph, queries, Int(args[3]))
    else:
        experiment[2](graph, queries, Int(args[3]))
    collection.close()
