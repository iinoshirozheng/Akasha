from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_entries import HnswEntry
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.hnsw_store import write_hnsw_snapshot
from akasha.storage.hnsw_overlay_cache import publish_hnsw_overlay_cache_best_effort
from akasha.storage.mapped_file import MappedFile
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


def test_snapshot_publication_does_not_copy_the_vector_tape() raises:
    var directory = String("/tmp/akasha-hnsw-stream-memory")
    ensure_directory(directory)
    var config = CollectionConfig.defaults(16384)
    config.ann_metric = MetricKind.dot()
    var index = HnswIndex(config)
    # A valid directed chain avoids measuring HNSW construction scratch.
    index.graph.vector_scalars = List[Float32](capacity=1024 * config.dimension)
    for id in range(1024):
        var slot = index.graph.append(id, List[Float32](length=config.dimension, fill=0.125), 0)
        if id > 0:
            _ = index.graph.add_neighbor(UInt32(id - 1), 0, slot)
    index.entry_slot = Optional(UInt32(0))
    index.entry_level = 0
    index.entries.primary.append(HnswEntry(0, 0))
    index.build_stats.slot_count = 1024
    index.build_stats.maximum_level = 0
    index.validate_structure()
    var before = _peak_rss_bytes()
    var info = write_hnsw_snapshot(directory + "/graph.bin", index, UInt64(7))
    var growth = _peak_rss_bytes() - before
    print("HNSW sidecar publication peak growth bytes:", growth)
    assert_true(growth < 16 * (1 << 20), "sidecar duplicates the vector tape")
    before = _peak_rss_bytes()
    assert_true(publish_hnsw_overlay_cache_best_effort(directory, index, 11, 13, 17, 7))
    growth = _peak_rss_bytes() - before
    print("HNSW overlay publication peak growth bytes:", growth)
    assert_true(growth < 16 * (1 << 20), "overlay duplicates the vector tape")
    # Inspect mappings only after both allocation measurements.
    var graph = MappedFile.open_readonly(directory + "/graph.bin")
    var cache = MappedFile.open_readonly(directory + "/hnsw-overlay.cache")
    assert_equal(graph.byte_length(), Int(info.byte_length))
    assert_equal(cache.byte_length(), graph.byte_length() + 40)
    assert_equal(graph.checksum(0, info.byte_length - 4), info.checksum)
    assert_equal(cache.checksum(36, info.byte_length - 4), info.checksum)
    assert_equal(cache.checksum(0, info.byte_length + 36), cache.load_scalars[DType.uint32, 1](cache.byte_length() - 4))
    remove_file_if_exists(directory + "/graph.bin")
    remove_file_if_exists(directory + "/hnsw-overlay.cache")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
