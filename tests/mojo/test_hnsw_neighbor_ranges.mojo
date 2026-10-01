from akasha.common.config import CollectionConfig
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_storage import HnswStorage
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import (
    encode_hnsw_snapshot,
    open_hnsw_snapshot_view,
)
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_raises, TestSuite


def _path(suffix: String) -> String:
    return String(
        "/tmp/akasha-neighbors-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
    )


def test_owned_neighbors_read_only_occupied_level_edges() raises:
    var graph = HnswStorage(2, 3, 6)
    for id in range(5):
        var values: List[Float32] = [Float32(id + 1), 1.0]
        _ = graph.append(id, values^, 3)
    for level in range(4):
        var links: List[UInt32] = [UInt32(level + 1)]
        graph.set_neighbors(0, level, links^)
    for slot in range(5):
        for level in range(4):
            var edges = graph.neighbor_range(UInt32(slot), level)
            assert_equal(edges[1], graph.neighbor_count(UInt32(slot), level))
            for i in range(edges[1]):
                assert_equal(
                    graph.neighbor_at_offset(edges[0] + i),
                    graph.neighbor_at(UInt32(slot), level, i),
                )
    with assert_raises():
        _ = graph.neighbor_range(UInt32.MAX, 0)
    with assert_raises():
        _ = graph.neighbor_range(0, -1)
    with assert_raises():
        _ = graph.neighbor_range(0, 4)
    for offset in [-1, len(graph.neighbor_slots), Int.MAX]:
        with assert_raises():
            _ = graph.neighbor_at_offset(offset)
    var saved_offset = graph.neighbor_range(0, 0)[0]
    graph.neighbor_counts[0] = UInt32.MAX
    with assert_raises():
        _ = graph.neighbor_range(0, 0)
    graph.neighbor_slots.clear()
    with assert_raises():
        _ = graph.neighbor_at_offset(saved_offset)


def test_mapped_neighbors_match_owned_at_every_level_and_reject_closed() raises:
    var config = CollectionConfig.defaults(2)
    config.m = 3
    config.m0 = 6
    config.ef_construction = 24
    config.max_level = 5
    var graph = HnswIndex(config)
    for id in range(32):
        var values: List[Float32] = [Float32(id + 1), Float32(id % 7)]
        graph.add(id, values^)
    var path = _path("graph")
    var bytes = encode_hnsw_snapshot(graph, 7)
    write_file_sync(path, bytes)
    var view = open_hnsw_snapshot_view(path, config, 7)
    for slot in range(graph.graph.slot_count()):
        for level in range(graph.graph.level(UInt32(slot)) + 1):
            var edges = view.neighbor_range(UInt32(slot), level)
            assert_equal(
                edges[1], graph.graph.neighbor_count(UInt32(slot), level)
            )
            for i in range(edges[1]):
                assert_equal(
                    view.neighbor_at_offset(edges[0] + i),
                    graph.graph.neighbor_at(UInt32(slot), level, i),
                )
    with assert_raises():
        _ = view.neighbor_range(UInt32.MAX, 0)
    with assert_raises():
        _ = view.neighbor_range(0, -1)
    var first_edge = view.neighbor_range(0, 0)[0]
    for offset in [-1, len(bytes) // 4, Int.MAX]:
        with assert_raises():
            _ = view.neighbor_at_offset(offset)
    view._edge_offset = Int.MAX
    with assert_raises():
        _ = view.neighbor_range(0, 0)
    view.close()
    with assert_raises():
        _ = view.neighbor_at_offset(first_edge)
    with assert_raises():
        _ = view.neighbor_range(0, 0)
    remove_file_if_exists(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
