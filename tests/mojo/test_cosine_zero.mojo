from akasha import CollectionConfig, MetricKind, ScalarKind, PersistentCollection
from akasha.index.hnsw import HnswIndex
from akasha.storage.hnsw_store import encode_hnsw_snapshot, decode_hnsw_snapshot_owned, open_hnsw_snapshot_view
from akasha.storage.filesystem import ensure_directory, write_file_sync
from std.ffi import c_int, external_call
from std.testing import assert_equal, TestSuite


def test_zero_cosine_owned_mapped_and_persisted_all_graph_scalars() raises:
    for scalar in [ScalarKind.f32(), ScalarKind.f16(), ScalarKind.bf16(), ScalarKind.i8()]:
        var config = CollectionConfig.defaults(3)
        config.ann_metric = MetricKind.cosine()
        config.scalar_kind = scalar.copy()
        var graph = HnswIndex(config)
        graph.add(1, [0.0, 0.0, 0.0])
        graph.add(2, [1.0, 0.0, 0.0])
        graph.add(3, [-1.0, 0.0, 0.0])
        var zero: List[Float32] = [0.0, 0.0, 0.0]
        var unit: List[Float32] = [1.0, 0.0, 0.0]
        var bytes = encode_hnsw_snapshot(graph, UInt64(1))
        var owned = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(1))
        var path = String("/tmp/akasha-cosine-zero-", Int(external_call["getpid", c_int]()), "-", scalar.name())
        ensure_directory(path)
        write_file_sync(path + "/graph.bin", bytes)
        var mapped = open_hnsw_snapshot_view(path + "/graph.bin", config, UInt64(1))
        var expected = graph.search(unit, 3)
        assert_equal(expected[0].id, 2)
        assert_equal(expected[1].id, 1)
        assert_equal(expected[1].score, Float32(0))
        assert_equal(expected[2].score, Float32(-1))
        var original_zero = graph.search(zero, 3)
        var owned_zero = owned.search(zero, 3)
        var mapped_zero = mapped.search(zero, 3)
        for hit in range(3):
            assert_equal(original_zero[hit].id, hit + 1)
            assert_equal(owned_zero[hit].id, hit + 1)
            assert_equal(mapped_zero[hit].id, hit + 1)
            assert_equal(original_zero[hit].score, Float32(0))
            assert_equal(owned_zero[hit].score, Float32(0))
            assert_equal(mapped_zero[hit].score, Float32(0))
        var collection = PersistentCollection.open_with_config(path + "/collection", config)
        collection.upsert(1, zero.copy())
        collection.upsert(2, unit.copy())
        collection.upsert(3, [-1.0, 0.0, 0.0])
        collection.flush()
        collection.close()
        var reopened = PersistentCollection.open_with_config(path + "/collection", config)
        var snapshot = reopened.snapshot()
        var queries: List[List[Float32]] = [zero.copy(), unit.copy()]
        var batch = snapshot.search_cosine_batch(queries, 3, num_workers=2)
        var parallel = snapshot.search_cosine_parallel(zero, 3, num_workers=2)
        for hit in range(3):
            assert_equal(batch[0][hit].id, hit + 1)
            assert_equal(batch[0][hit].score, Float32(0))
            assert_equal(batch[1][hit].id, expected[hit].id)
            assert_equal(batch[1][hit].score, expected[hit].score)
            assert_equal(parallel[hit].id, hit + 1)
            assert_equal(parallel[hit].score, Float32(0))
        snapshot.close()
        reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
