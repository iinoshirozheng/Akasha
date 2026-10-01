from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import (
    encode_hnsw_snapshot,
    open_hnsw_snapshot_view,
)
from std.ffi import c_int, external_call
from std.math import abs
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def _check[tag: Int]() raises:
    for dimension in [31, 63, 64, 65, 127, 384, 769, 1536]:
        var config = CollectionConfig.defaults(dimension)
        config.ann_metric = MetricKind.dot()
        comptime if tag == 1:
            config.ann_metric = MetricKind.l2()
        elif tag == 2:
            config.ann_metric = MetricKind.cosine()
        var index = HnswIndex(config)
        var query = List[Float32]()
        for row in range(8):
            var values = List[Float32]()
            for column in range(dimension):
                values.append(
                    Float32((row * 17 + column * 31) % 97 - 48) / 37.0
                )
            if row == 3:
                query = values.copy()
            index.add(-row * 13, values^)
        var prepared = index.distance_backend.prepare_query(query)
        var path = String(
            "/tmp/akasha-hnsw-accumulators-",
            Int(external_call["getpid", c_int]()),
            ".bin",
        )
        write_file_sync(path, encode_hnsw_snapshot(index, UInt64(17)))
        var view = open_hnsw_snapshot_view(path, config, UInt64(17))
        for row in range(8):
            var product = Float64(0)
            var squared_l2 = Float64(0)
            var between_product = Float64(0)
            var between_l2 = Float64(0)
            for column in range(dimension):
                var lhs = Float64(prepared[column])
                var rhs = Float64(index.graph.vector_value(UInt32(row), column))
                var member = Float64(
                    index.graph.vector_value(UInt32(3), column)
                )
                product += lhs * rhs
                squared_l2 += (lhs - rhs) * (lhs - rhs)
                between_product += member * rhs
                between_l2 += (member - rhs) * (member - rhs)
            var expected = -product
            var between_expected = -between_product
            comptime if tag == 1:
                expected = squared_l2
                between_expected = between_l2
            elif tag == 2:
                expected = max(Float64(0), min(Float64(2), 1 - product))
                between_expected = max(
                    Float64(0), min(Float64(2), 1 - between_product)
                )
            var actual = index.graph._distance_to_slot_backend[tag](
                index.metric, prepared, UInt32(row)
            )
            var mapped = view._distance_to_slot_backend[tag](
                index.metric, prepared, UInt32(row)
            )
            var between = index.graph._distance_between_backend[tag](
                index.metric, UInt32(3), UInt32(row)
            )
            assert_true(
                abs(Float64(actual) - expected)
                <= 2.0e-6 * max(Float64(1), abs(expected))
            )
            assert_true(
                abs(Float64(between) - between_expected)
                <= 2.0e-6 * max(Float64(1), abs(between_expected))
            )
            assert_equal(actual, mapped)
        var owned_results = index.search(query, 8, ef_search=16)
        var mapped_results = view.search(query, 8, ef_search=16)
        assert_equal(len(owned_results), len(mapped_results))
        for row in range(len(owned_results)):
            assert_equal(owned_results[row].id, mapped_results[row].id)
            assert_equal(owned_results[row].score, mapped_results[row].score)
        with assert_raises():
            _ = view._distance_to_slot_backend[tag](
                index.metric, prepared, UInt32(8)
            )
        view.close()
        with assert_raises():
            _ = view._distance_to_slot_backend[tag](
                index.metric, prepared, UInt32(0)
            )
        remove_file_if_exists(path)


def test_dot_accumulator_oracle_and_mapped_parity() raises:
    _check[0]()


def test_l2_accumulator_oracle_and_mapped_parity() raises:
    _check[1]()


def test_cosine_accumulator_oracle_and_mapped_parity() raises:
    _check[2]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
