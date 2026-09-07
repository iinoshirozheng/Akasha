from akasha.compute.gpu.flat_scan import execute_device_batch
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.query.batch_executor import (
    BATCH_COSINE_METRIC,
    BATCH_DOT_METRIC,
    BATCH_L2_METRIC,
    execute_exact_batch,
)
from akasha.storage.memtable import MemTable
from std.math import abs
from std.testing import assert_equal, assert_true, TestSuite


def test_real_gpu_batch_scores_and_topk_match_cpu() raises:
    var table = MemTable(7)
    for id in range(1, 70):
        table.apply_upsert(
            id,
            UInt64(id),
            [
                Float32(id % 11) + 0.25,
                Float32(id % 13),
                Float32(id % 17),
                Float32(id % 19),
                Float32(id % 23),
                Float32(id % 29),
                Float32(id % 31),
            ],
        )
    # Exact ties must prefer ascending IDs on both device and CPU.
    table.apply_upsert(100, UInt64(100), [9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0])
    table.apply_upsert(99, UInt64(101), [9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0])
    var queries = List[List[Float32]]()
    queries.append([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0])
    queries.append([7.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0])
    var options = GpuExecutionOptions(enabled=True, min_work_items=1)
    for metric in [BATCH_DOT_METRIC, BATCH_L2_METRIC, BATCH_COSINE_METRIC]:
        var expected = execute_exact_batch(table, queries, 8, metric, 1)
        var actual = execute_device_batch[use_accelerator=True](
            table, queries, 8, metric, options
        )
        assert_true(actual.used_gpu)
        assert_equal(actual.reason, "gpu executed")
        for query_index in range(len(expected)):
            for result_index in range(len(expected[query_index])):
                assert_equal(
                    actual.results[query_index][result_index].id,
                    expected[query_index][result_index].id,
                )
                assert_true(
                    abs(
                        actual.results[query_index][result_index].score
                        - expected[query_index][result_index].score
                    )
                    <= 1.0e-4
                )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
