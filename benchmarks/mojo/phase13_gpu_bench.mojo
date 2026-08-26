from akasha.compute.gpu.flat_scan import execute_device_batch
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.index.flat import SearchResult
from akasha.query.batch_executor import BATCH_L2_METRIC, execute_exact_batch
from akasha.storage.memtable import MemTable
from std.math import abs
from std.time import perf_counter_ns


comptime _DIMENSION = 32
comptime _POINTS = 2_000
comptime _ITERATIONS = 5


def _vector(seed: Int) -> List[Float32]:
    var values = List[Float32](capacity=_DIMENSION)
    for column in range(_DIMENSION):
        values.append(
            Float32((seed * 31 + column * 17 + seed * column) % 257)
            / 41.0
            + 0.01
        )
    return values^


def _p95(var values: List[Int]) -> Int:
    for index in range(1, len(values)):
        var cursor = index
        while cursor > 0 and values[cursor] < values[cursor - 1]:
            values.swap_elements(cursor, cursor - 1)
            cursor -= 1
    return values[(len(values) * 95 + 99) // 100 - 1]


def _verify(
    lhs: List[List[SearchResult]], rhs: List[List[SearchResult]]
) raises:
    if len(lhs) != len(rhs):
        raise Error("Phase 13 batch count mismatch")
    for query_index in range(len(lhs)):
        if len(lhs[query_index]) != len(rhs[query_index]):
            raise Error("Phase 13 result count mismatch")
        for result_index in range(len(lhs[query_index])):
            if (
                lhs[query_index][result_index].id
                != rhs[query_index][result_index].id
            ):
                raise Error("Phase 13 GPU ID differential gate failed")
            if (
                abs(
                    lhs[query_index][result_index].score
                    - rhs[query_index][result_index].score
                )
                > 1.0e-4
            ):
                raise Error("Phase 13 GPU score differential gate failed")


def _run_workload(table: MemTable, batch_size: Int) raises:
    var queries = List[List[Float32]](capacity=batch_size)
    for query_index in range(batch_size):
        queries.append(_vector(50_000 + query_index))
    var cpu_start = perf_counter_ns()
    var expected = execute_exact_batch(
        table, queries, 10, BATCH_L2_METRIC, 0
    )
    var cpu_ns = perf_counter_ns() - cpu_start
    var options = GpuExecutionOptions(min_work_items=1)
    var warmup = execute_device_batch[use_accelerator=True](
        table, queries, 10, BATCH_L2_METRIC, options
    )
    if not warmup.used_gpu:
        raise Error("Phase 13 benchmark did not execute on GPU")
    _verify(expected, warmup.results)
    var samples = List[Int](capacity=_ITERATIONS)
    for _ in range(_ITERATIONS):
        var start = perf_counter_ns()
        var actual = execute_device_batch[use_accelerator=True](
            table, queries, 10, BATCH_L2_METRIC, options
        )
        samples.append(perf_counter_ns() - start)
        if not actual.used_gpu:
            raise Error("Phase 13 benchmark unexpectedly fell back")
        _verify(expected, actual.results)
    var p95 = _p95(samples^)
    print(
        "phase13 batch",
        batch_size,
        "points",
        _POINTS,
        "dimension",
        _DIMENSION,
        "cpu ns/query",
        Float64(cpu_ns) / Float64(batch_size),
        "gpu e2e p95 ns/query",
        Float64(p95) / Float64(batch_size),
    )


def main() raises:
    var table = MemTable(_DIMENSION)
    for id in range(1, _POINTS + 1):
        var vector = _vector(id)
        table.apply_upsert(id, UInt64(id), vector^)
    _run_workload(table, 1)
    _run_workload(table, 8)
    _run_workload(table, 32)
