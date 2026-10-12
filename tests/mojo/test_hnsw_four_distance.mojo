from akasha.common.config import CollectionConfig, MetricKind, ScalarKind
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_storage import HnswGraphAccess
from akasha.storage.hnsw_store import encode_hnsw_snapshot, open_hnsw_snapshot_view
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from std.ffi import c_int, external_call
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def four[tag: Int, Graph: HnswGraphAccess](graph: Graph, metric: MetricDispatcher, query: List[Float32], slots: SIMD[DType.uint32, 4]) raises -> SIMD[DType.float32, 4]:
    return graph._distance_to_four_f32[tag](metric, query, slots)


def check[tag: Int, Graph: HnswGraphAccess](graph: Graph, metric: MetricDispatcher, query: List[Float32]) raises:
    var slots = SIMD[DType.uint32, 4](0)
    slots[0] = 6
    slots[1] = 0
    slots[2] = 2
    slots[3] = 4
    for repeated in [False, True]:
        if repeated:
            slots = SIMD[DType.uint32, 4](6)
        var scores = four[tag](graph, metric, query, slots)
        comptime for lane in range(4):
            var expected = graph._distance_to_slot_backend[tag](metric, query, slots[lane])
            assert_equal(bitcast[DType.uint32](scores[lane]), bitcast[DType.uint32](expected))
    with assert_raises(contains="dimension"):
        _ = four[tag](graph, metric, List[Float32](), slots)
    for lane in range(4):
        var invalid = slots
        invalid[lane] = UInt32(graph.slot_count())
        with assert_raises(contains="bound"):
            _ = four[tag](graph, metric, query, invalid)


def exercise[tag: Int]() raises:
    for dimension in [1, 3, 4, 15, 16, 17, 31, 63, 64, 65, 127, 128, 129, 1536]:
        var config = CollectionConfig.defaults(dimension)
        config.scalar_kind = ScalarKind.f32()
        config.m = 4
        config.m0 = 8
        config.ef_construction = 16
        comptime if tag == 0:
            config.ann_metric = MetricKind.dot()
        elif tag == 1:
            config.ann_metric = MetricKind.l2()
        else:
            config.ann_metric = MetricKind.cosine()
        var index = HnswIndex(config.copy())
        for row in range(7):
            var values = List[Float32]()
            for column in range(dimension):
                var value = Float32((row * 7 + column * 11) % 29 - 14) / 17
                if column == 0 and value == 0:
                    value = 0.25
                values.append(value)
            index.add(row - 3, values)
        var query = List[Float32]()
        for column in range(dimension):
            query.append(Float32((column * 17 + 3) % 37 - 18) / 19)
        var prepared = index.metric.prepare_query(query)
        var path = String("/tmp/akasha-four-distance-", Int(external_call["getpid", c_int]()), "-", dimension, "-", tag, ".hnsw")
        remove_file_if_exists(path)
        write_file_sync(path, encode_hnsw_snapshot(index, UInt64(1)))
        var view = open_hnsw_snapshot_view(path, config, UInt64(1))
        check[tag](index.graph, index.metric, prepared)
        check[tag](view, index.metric, prepared)
        view.close()
        with assert_raises():
            _ = four[tag](view, index.metric, prepared, SIMD[DType.uint32, 4](0))
        remove_file_if_exists(path)


def test_dot_four_rows_keep_bits_and_bounds() raises:
    exercise[0]()


def test_l2_four_rows_keep_bits_and_bounds() raises:
    exercise[1]()


def test_cosine_four_rows_keep_bits_and_bounds() raises:
    exercise[2]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
