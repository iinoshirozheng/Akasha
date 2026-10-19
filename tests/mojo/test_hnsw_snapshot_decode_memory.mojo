from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_entries import HnswEntry
from akasha.storage.hnsw_store import (
    decode_hnsw_snapshot_owned,
    encode_hnsw_snapshot,
)
from std.ffi import c_int, external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, TestSuite


def _peak_rss_bytes() -> Int:
    var usage = List[Int64](length=32, fill=0)
    _ = external_call["getrusage", c_int](c_int(0), usage.unsafe_ptr())
    comptime if CompilationTarget.is_macos():
        return Int(usage[4])
    else:
        return Int(usage[4]) * 1024


def test_owned_decode_allocates_only_one_vector_tape() raises:
    var config = CollectionConfig.defaults(16384)
    config.ann_metric = MetricKind.dot()
    var index = HnswIndex(config)
    var scalars = 1024 * config.dimension
    index.graph.vector_scalars.reserve(scalars)
    # A directed chain isolates decoding from construction/search scratch.
    for id in range(1024):
        var slot = index.graph.append(
            id, List[Float32](length=config.dimension, fill=0.125), 0
        )
        if id > 0:
            _ = index.graph.add_neighbor(UInt32(id - 1), 0, slot)
    index.entry_slot = Optional(UInt32(0))
    index.entry_level = 0
    index.entries.primary.append(HnswEntry(0, 0))
    index.build_stats.slot_count = 1024
    index.build_stats.maximum_level = 0
    var bytes = encode_hnsw_snapshot(index, 7)
    var before = _peak_rss_bytes()
    var decoded = decode_hnsw_snapshot_owned(bytes^, config, 7)
    var growth = _peak_rss_bytes() - before
    print("HNSW owned decode peak growth bytes:", growth)
    # The 64 MiB output plus bounded graph metadata fits below 96 MiB;
    # retaining a second full decoded tape exceeds this limit.
    assert_true(growth < 96 * (1 << 20), "decoder duplicates the vector tape")
    assert_equal(decoded.graph.vector_scalars, index.graph.vector_scalars)
    assert_equal(decoded.point_count(), index.point_count())
    assert_equal(decoded.build_stats.directed_edges, 1023)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
