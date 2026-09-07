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
                            enabled=True,
                            min_work_items=1,
                            block_size=block_size,
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


def _random_signed(mut state: UInt64) -> Float32:
    state += UInt64(0x9E3779B97F4A7C15)
    var value = state
    value = (value ^ (value >> 30)) * UInt64(0xBF58476D1CE4E5B9)
    value = (value ^ (value >> 27)) * UInt64(0x94D049BB133111EB)
    value ^= value >> 31
    return Float32(UInt32(value & 0x00FFFFFF)) / 8_388_608.0 - 1.0


def test_near_tie_at_k_boundary_matches_cpu_accumulation_groups() raises:
    # Reduced from seed 12345, N=32768, D=768, query 81 of a 128-query batch.
    # CPU scores tie at 450.614; a dimension/warp-size sum excluded ID 8465.
    var rng = UInt64(12345)
    var left = List[Float32]()
    var right = List[Float32]()
    for point in range(32768):
        for _ in range(768):
            var value = _random_signed(rng)
            if 32768 - point == 8465:
                left.append(value)
            if 32768 - point == 20590:
                right.append(value)
    var query = List[Float32]()
    for index in range(82):
        for _ in range(768):
            var value = _random_signed(rng)
            if index == 81:
                query.append(value)
    var table = MemTable(768)
    table.apply_upsert(8465, 1, left^)
    for index in range(255):
        table.apply_upsert(
            index, UInt64(index + 2), List[Float32](length=768, fill=10000.0)
        )
    table.apply_upsert(20590, 257, right^)
    var queries = List[List[Float32]]()
    queries.append(query^)
    var candidates = List[List[Int]]()
    var state = GpuSnapshotState(sequence=table.last_sequence)
    for block in [7, 32, 256]:
        var expected = execute_exact_batch(table, queries, 1, 1, 1)
        var actual = execute_snapshot_device_batch[True](
            table,
            queries,
            candidates,
            False,
            1,
            1,
            GpuExecutionOptions(
                enabled=True, min_work_items=1, block_size=block
            ),
            state,
        )
        assert_true(actual.used_gpu)
        assert_equal(expected[0][0].id, 8465)
        assert_equal(actual.results[0][0].id, expected[0][0].id)
        assert_equal(actual.results[0][0].score, expected[0][0].score)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
