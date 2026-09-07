from akasha.compute.gpu.context import GpuSnapshotState
from akasha.compute.gpu.flat_scan import execute_snapshot_device_batch
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.query.batch_executor import (
    execute_exact_batch,
    execute_exact_candidate_batch,
)
from akasha.storage.memtable import MemTable
from std.math import abs
from std.testing import assert_equal, assert_true, TestSuite


def test_partition_merge_ties_ragged_large_k_and_partial_warps() raises:
    var table = MemTable(33)
    for point in range(769):
        var values = List[Float32]()
        for column in range(33):
            # Binary fractions keep dot/L2 ties exact across reduction orders.
            values.append(Float32((point % 17 + column * 3) % 23 - 11) / 8.0)
        var id = (769 - point) * 10_000_000_000 - 4_000_000_000_000
        table.apply_upsert(id, UInt64(point + 1), values^)
    var queries = List[List[Float32]]()
    var candidates = List[List[Int]]()
    for query in range(4):
        var values = List[Float32]()
        for column in range(33):
            values.append(Float32((query + column * 5) % 13 - 6) / 4.0)
        queries.append(values^)
        var slots = List[Int]()
        for point in range(769):
            if (
                query == 0
                or (query == 1 and point % 2 == 0)
                or (query == 2 and point == 768)
            ):
                slots.append(point)
        candidates.append(slots^)
    var state = GpuSnapshotState(sequence=table.last_sequence)
    for metric in [0, 1, 2]:
        for block_size in [7, 32, 256]:
            for k in [1, 10, 257, 800]:
                for filtered in [False, True]:
                    var expected = execute_exact_batch(
                        table, queries, k, metric, 1
                    )
                    if filtered:
                        expected = execute_exact_candidate_batch(
                            table, queries, candidates, k, metric, 1
                        )
                    var actual = execute_snapshot_device_batch[True](
                        table,
                        queries,
                        candidates,
                        filtered,
                        k,
                        metric,
                        GpuExecutionOptions(
                            min_work_items=1, block_size=block_size
                        ),
                        state,
                    )
                    assert_true(actual.used_gpu)
                    assert_true(
                        actual.timings.resident_bytes
                        <= UInt64(512 * 1024 * 1024)
                    )
                    for query in range(len(queries)):
                        assert_equal(
                            len(actual.results[query]), len(expected[query])
                        )
                        for rank in range(len(expected[query])):
                            assert_equal(
                                actual.results[query][rank].id,
                                expected[query][rank].id,
                            )
                            assert_true(
                                abs(
                                    actual.results[query][rank].score
                                    - expected[query][rank].score
                                )
                                < 1.0e-4
                            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
