from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.index.hnsw import HnswIndex
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import (
    decode_hnsw_snapshot_mapped,
    encode_hnsw_snapshot,
)
from akasha.storage.mapped_file import MappedFile
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def test_mapped_subrange_decode_owns_every_scalar_kind_after_unmap() raises:
    var path = String("/tmp/akasha-hnsw-mapped-decode.bin")
    for scalar in [ScalarKind.f32(), ScalarKind.f16(), ScalarKind.bf16(), ScalarKind.i8()]:
        for metric in [MetricKind.dot(), MetricKind.cosine()]:
            var config = CollectionConfig.defaults(3)
            config.scalar_kind = scalar.copy()
            config.ann_metric = metric.copy()
            var graph = HnswIndex(config)
            for id in range(-4, 12):
                graph.add(id, [Float32(id), 1.0, -2.0])
            graph.upsert(-4, [0.0, 2.0, 1.0])
            assert_true(graph.delete(3))
            var snapshot = encode_hnsw_snapshot(graph, 23)
            # Neither the snapshot nor its scalar sections are naturally aligned.
            var bytes = List[UInt8](length=3, fill=0xFF)
            bytes.extend(Span(snapshot))
            bytes.extend(Span(List[UInt8](length=64, fill=0)))
            write_file_sync(path, bytes)
            var mapping = MappedFile.open_readonly(path)
            var decoded = decode_hnsw_snapshot_mapped(
                mapping, 3, len(snapshot), config, 23
            )
            mapping.close()
            remove_file_if_exists(path)
            assert_equal(encode_hnsw_snapshot(decoded, 23), snapshot)
            assert_equal(decoded.inactive_count(), graph.inactive_count())
            var expected = graph.search([1.0, 2.0, 3.0], 5)
            var actual = decoded.search([1.0, 2.0, 3.0], 5)
            for index in range(len(expected)):
                assert_equal(actual[index].id, expected[index].id)
                assert_equal(actual[index].score, expected[index].score)


def test_mapped_snapshot_cannot_read_outside_its_payload() raises:
    var config = CollectionConfig.defaults(2)
    var graph = HnswIndex(config)
    graph.add(1, [1.0, 2.0])
    var snapshot = encode_hnsw_snapshot(graph, 7)
    var bytes = List[UInt8](length=1, fill=0)
    bytes.extend(Span(snapshot))
    bytes.extend(Span(snapshot))
    var path = String("/tmp/akasha-hnsw-mapped-decode-bounds.bin")
    write_file_sync(path, bytes)
    var mapping = MappedFile.open_readonly(path)
    for offset in [-1, Int.MAX]:
        with assert_raises():
            _ = decode_hnsw_snapshot_mapped(mapping, offset, len(snapshot), config, 7)
    for length in [-1, 0, 11, len(snapshot) - 1, len(snapshot) + 1, Int.MAX]:
        with assert_raises():
            _ = decode_hnsw_snapshot_mapped(mapping, 1, length, config, 7)
    with assert_raises():
        _ = decode_hnsw_snapshot_mapped(mapping, 1, len(snapshot), config, 8)
    mapping.close()
    remove_file_if_exists(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
