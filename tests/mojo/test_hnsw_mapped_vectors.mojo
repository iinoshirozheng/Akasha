from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.index.hnsw import HnswIndex
from akasha.storage.checksum import crc32_range
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import (
    decode_hnsw_snapshot_owned,
    encode_hnsw_snapshot,
    open_hnsw_snapshot_view,
)
from std.ffi import c_int, external_call
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def _path() -> String:
    return String("/tmp/akasha-mapped-vector-read-", Int(external_call["getpid", c_int]()), ".bin")


def _config(dimension: Int, metric: MetricKind) -> CollectionConfig:
    var config = CollectionConfig.defaults(dimension)
    config.ann_metric = metric.copy()
    config.scalar_kind = ScalarKind.f32()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 16
    config.default_ef_search = 16
    return config^


def _vector(dimension: Int, id: Int) -> List[Float32]:
    var values = List[Float32](capacity=dimension)
    for component in range(dimension):
        values.append(Float32(((component + 1) * (id + 3)) % 23 - 11) * 0.125)
    # Include both signed zeros and a subnormal, while keeping cosine nonzero.
    if dimension >= 4:
        values[1] = Float32(0.0)
        values[2] = bitcast[DType.float32](UInt32(0x80000000))
        values[3] = bitcast[DType.float32](UInt32(1))
    return values^


def _graph(config: CollectionConfig) raises -> HnswIndex:
    var graph = HnswIndex(config)
    for id in range(1, 6):
        graph.add(id, _vector(config.dimension, id))
    graph.upsert(2, _vector(config.dimension, 9))
    assert_true(graph.delete(4))
    return graph^


def _put_u32(mut bytes: List[UInt8], offset: Int, value: UInt32):
    for index in range(4):
        bytes[offset + index] = UInt8(value >> UInt32(index * 8))


def _put_u64(mut bytes: List[UInt8], offset: Int, value: UInt64):
    for index in range(8):
        bytes[offset + index] = UInt8(value >> UInt64(index * 8))


def _u64_at(bytes: List[UInt8], offset: Int) -> UInt64:
    var value = UInt64(0)
    for index in range(8):
        value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
    return value


def _seal(mut bytes: List[UInt8]):
    _put_u32(bytes, len(bytes) - 4, crc32_range(bytes, 0, len(bytes) - 4))


def _reject(bytes: List[UInt8], config: CollectionConfig) raises:
    with assert_raises():
        _ = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(93))
    var path = _path()
    write_file_sync(path, bytes)
    with assert_raises():
        _ = open_hnsw_snapshot_view(path, config, UInt64(93))
    remove_file_if_exists(path)


def test_f32_mapped_validation_preserves_rows_and_scores_across_tails() raises:
    var dimensions: List[Int] = [1, 3, 15, 16, 17, 31, 32, 33, 1536, 1537]
    var metrics: List[MetricKind] = [MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()]
    for dimension in dimensions:
        for metric in metrics:
            var config = _config(dimension, metric)
            var graph = _graph(config)
            var bytes = encode_hnsw_snapshot(graph, UInt64(93))
            var owned = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(93))
            var path = _path()
            write_file_sync(path, bytes)
            var view = open_hnsw_snapshot_view(path, config, UInt64(93))
            view.validate_structure()
            assert_equal(view.slot_count(), owned.graph.slot_count())
            for slot_index in range(view.slot_count()):
                var slot = UInt32(slot_index)
                assert_equal(view.is_current(slot), owned.graph.is_current(slot))
                for component in range(dimension):
                    assert_equal(
                        bitcast[DType.uint32](view.vector_value(slot, component)),
                        bitcast[DType.uint32](owned.graph.vector_value(slot, component)),
                    )
            var query = _vector(dimension, 10)
            var expected = owned.search(query, 4, ef_search=16)
            var actual = view.search(query, 4, ef_search=16)
            assert_equal(len(actual), len(expected))
            for index in range(len(actual)):
                assert_equal(actual[index].id, expected[index].id)
                assert_equal(actual[index].score, expected[index].score)
            view.close()
            with assert_raises():
                view.validate_structure()
            remove_file_if_exists(path)


def test_f32_mapped_validation_rejects_invalid_values_in_chunks_and_tails() raises:
    var metrics: List[MetricKind] = [MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()]
    var positions: List[Int] = [0, 15, 16, 31, 32]
    var bad_bits: List[UInt32] = [0x7FC00001, 0x7F800001, 0x7F800000, 0xFF800000, 0x7F7FFFFF]
    for metric in metrics:
        var config = _config(33, metric)
        var bytes = encode_hnsw_snapshot(_graph(config), UInt64(93))
        var vector_offset = Int(_u64_at(bytes, 104))
        # Slot 1 is the replaced inactive record, slot 5 the last live row.
        var slots: List[Int] = [1, 5]
        for slot in slots:
            for position in positions:
                for bits in bad_bits:
                    var corrupt = bytes.copy()
                    _put_u32(corrupt, vector_offset + (slot * 33 + position) * 4, bits)
                    _seal(corrupt)
                    _reject(corrupt, config)


def test_f32_mapped_validation_rejects_zero_and_nonunit_cosine_rows() raises:
    var config = _config(33, MetricKind.cosine())
    var bytes = encode_hnsw_snapshot(_graph(config), UInt64(93))
    var vector_offset = Int(_u64_at(bytes, 104))
    var zero = bytes.copy()
    for component in range(33):
        _put_u32(zero, vector_offset + component * 4, 0)
    _seal(zero)
    _reject(zero, config)
    _put_u32(zero, vector_offset + 32 * 4, bitcast[DType.uint32](Float32(2.0)))
    _seal(zero)
    _reject(zero, config)


def test_f32_mapped_validation_rejects_short_and_overlapping_vector_tapes() raises:
    var config = _config(33, MetricKind.l2())
    var bytes = encode_hnsw_snapshot(_graph(config), UInt64(93))
    var short_length = bytes.copy()
    _put_u64(short_length, 112, _u64_at(bytes, 112) - 4)
    _seal(short_length)
    _reject(short_length, config)
    var overlap = bytes.copy()
    _put_u64(overlap, 104, _u64_at(bytes, 104) - 8)
    _seal(overlap)
    _reject(overlap, config)
    var truncated = bytes.copy()
    _ = truncated.pop()
    _reject(truncated, config)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
