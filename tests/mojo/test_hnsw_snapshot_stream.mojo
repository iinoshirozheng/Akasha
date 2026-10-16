from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_entries import HnswEntry
from akasha.storage.filesystem import ensure_directory, read_file_bytes, write_file_sync, remove_file_if_exists
from akasha.storage.hnsw_store import encode_hnsw_snapshot, write_hnsw_snapshot, open_hnsw_snapshot_view
from akasha.storage.hnsw_overlay_cache import publish_hnsw_overlay_cache_best_effort
from akasha.storage.index_cache import CacheArtifact, CACHE_HNSW_OVERLAY_KIND, encode_cache
from std.testing import assert_equal, assert_false, assert_raises, TestSuite
from std.memory import bitcast


def _config(metric: Int, scalar: Int) -> CollectionConfig:
    var metrics: List[MetricKind] = [MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()]
    var scalars: List[ScalarKind] = [ScalarKind.f32(), ScalarKind.bf16(), ScalarKind.f16(), ScalarKind.i8()]
    var config = CollectionConfig.defaults(5)
    config.ann_metric = metrics[metric].copy()
    config.scalar_kind = scalars[scalar].copy()
    config.m = 4
    config.m0 = 8
    config.max_level = 4
    config.ef_construction = 24
    config.level_seed = UInt64(0x17A5A17A5)
    return config^


def _graph(config: CollectionConfig, populated: Bool) raises -> HnswIndex:
    var index = HnswIndex(config)
    if populated:
        for id in range(24):
            index.add(id, [Float32(id % 7) * 0.25, -1.5, Float32(id % 3), 0.0, 2.0])
        _ = index.delete(3)
        index.upsert(7, [0.5, 0.0, 1.0, 2.0, -3.0])
    return index^


def _fixture(metric: Int, scalar: Int, populated: Int) -> String:
    return String("tests/fixtures/hnsw-stream/", metric, "-", scalar, "-", populated, ".bin")


def test_streamed_sidecars_and_overlay_equal_frozen_owned_bytes() raises:
    var directory = String("/tmp/akasha-hnsw-stream")
    ensure_directory(directory)
    for metric in range(3):
        for scalar in range(4):
            if metric == 1 and scalar == 3:
                continue  # L2/I8 is not a supported collection configuration.
            for populated in range(2):
                var config = _config(metric, scalar)
                var index = _graph(config, Bool(populated))
                var frozen = read_file_bytes(_fixture(metric, scalar, populated))
                assert_equal(encode_hnsw_snapshot(index, UInt64(7)), frozen)
                var info = write_hnsw_snapshot(directory + "/graph.bin", index, UInt64(7))
                assert_equal(read_file_bytes(directory + "/graph.bin"), frozen)
                assert_equal(info.byte_length, UInt64(len(frozen)))
                var view = open_hnsw_snapshot_view(directory + "/graph.bin", config, UInt64(7))
                assert_equal(view.slot_count(), index.graph.slot_count())
                assert_equal(publish_hnsw_overlay_cache_best_effort(directory, index, 11, 13, 17, 7), True)
                var artifact = CacheArtifact(CACHE_HNSW_OVERLAY_KIND, 5, 11, 13, 17, frozen^)
                assert_equal(read_file_bytes(directory + "/hnsw-overlay.cache"), encode_cache(artifact))


def test_invalid_graph_cannot_truncate_sidecar_or_replace_overlay() raises:
    var directory = String("/tmp/akasha-hnsw-stream-invalid")
    ensure_directory(directory)
    var old: List[UInt8] = [1, 2, 3, 4]
    write_file_sync(directory + "/graph.bin", old)
    write_file_sync(directory + "/hnsw-overlay.cache", old)
    var config = _config(0, 0)
    var index = _graph(config, True)
    index.graph.vector_scalars[0] = bitcast[DType.float32](UInt32(0x7FC00000))
    with assert_raises():
        _ = write_hnsw_snapshot(directory + "/graph.bin", index, UInt64(7))
    assert_equal(read_file_bytes(directory + "/graph.bin"), old)
    assert_false(publish_hnsw_overlay_cache_best_effort(directory, index, 11, 13, 17, 7))
    assert_equal(read_file_bytes(directory + "/hnsw-overlay.cache"), old)


def test_streaming_across_chunk_boundaries_for_all_scalar_kinds() raises:
    var directory = String("/tmp/akasha-hnsw-stream-chunks")
    ensure_directory(directory)
    for scalar in range(4):
        var config = _config(0, scalar)
        config.dimension = 33
        var index = HnswIndex(config)
        for id in range(2049):
            var row = List[Float32](length=config.dimension, fill=Float32(id % 5 + 1) * 0.25)
            var prepared = index.metric.prepare_graph_vector(row)
            var slot = index.graph.append(id, prepared^, 0)
            if id > 0:
                _ = index.graph.add_neighbor(UInt32(id - 1), 0, slot)
        index.entry_slot = Optional(UInt32(0))
        index.entry_level = 0
        index.entries.primary.append(HnswEntry(0, 0))
        index.build_stats.slot_count = 2049
        index.build_stats.maximum_level = 0
        var expected = encode_hnsw_snapshot(index, 7)
        var info = write_hnsw_snapshot(directory + "/graph.bin", index, 7)
        assert_equal(read_file_bytes(directory + "/graph.bin"), expected)
        var view = open_hnsw_snapshot_view(directory + "/graph.bin", config, 7)
        assert_equal(view.slot_count(), 2049)
        assert_equal(info.byte_length, UInt64(len(expected)))


def test_overlay_io_failure_preserves_published_file() raises:
    var directory = String("/tmp/akasha-hnsw-stream-failure")
    ensure_directory(directory)
    var temporary = directory + "/hnsw-overlay.cache.tmp"
    ensure_directory(temporary)
    var old: List[UInt8] = [9, 8, 7]
    write_file_sync(directory + "/hnsw-overlay.cache", old)
    var index = _graph(_config(0, 0), True)
    assert_false(publish_hnsw_overlay_cache_best_effort(directory, index, 11, 13, 17, 7))
    assert_equal(read_file_bytes(directory + "/hnsw-overlay.cache"), old)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
