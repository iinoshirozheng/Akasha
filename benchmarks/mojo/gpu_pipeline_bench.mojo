from akasha.api.snapshot import ReadSnapshot
from akasha.common.config import CollectionConfig
from akasha.compute.gpu.flat_scan import DeviceBatchResult, execute_device_batch
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.index.flat import SearchResult
from akasha.index.sparse import SparseIndex
from akasha.query.batch_executor import execute_exact_batch
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable
from hnsw_quality import SplitMix64, _uniform_vector
from std.math import abs
from std.memory import ArcPointer
from std.sys.arg import argv
from std.time import perf_counter_ns


def _same(
    expected: List[List[SearchResult]], actual: List[List[SearchResult]]
) raises:
    if len(expected) != len(actual):
        raise Error("GPU benchmark batch count differs")
    for query in range(len(expected)):
        if len(expected[query]) != len(actual[query]):
            raise Error("GPU benchmark result count differs")
        for rank in range(len(expected[query])):
            if expected[query][rank].id != actual[query][rank].id:
                raise Error("GPU benchmark ID differential failed")
            var score = expected[query][rank].score
            if abs(actual[query][rank].score - score) > 1.0e-4 + 1.0e-5 * abs(
                score
            ):
                raise Error("GPU benchmark score differential failed")


def _resident_report(
    snapshot: ReadSnapshot, queries: List[List[Float32]], metric: Int,
    options: GpuExecutionOptions,
) raises -> DeviceBatchResult:
    if metric == 0:
        return snapshot.search_device_dot_batch[True](queries, 10, options)
    if metric == 1:
        return snapshot.search_device_l2_batch[True](queries, 10, options)
    return snapshot.search_device_cosine_batch[True](queries, 10, options)


def _resident(
    snapshot: ReadSnapshot, queries: List[List[Float32]], metric: Int,
    options: GpuExecutionOptions,
) raises -> List[List[SearchResult]]:
    var report = _resident_report(snapshot, queries, metric, options)
    if not report.used_gpu:
        raise Error(report.reason)
    return report.take_results()


def main() raises:
    var args = argv()
    if len(args) != 6:
        raise Error(
            "usage: gpu-bench POINTS DIMENSION BATCH SAMPLES METRIC_TAG"
        )
    var points = Int(args[1])
    var dimension = Int(args[2])
    var batch = Int(args[3])
    var samples = Int(args[4])
    var metric = Int(args[5])
    if points < 10 or dimension < 1 or batch < 1 or samples < 1:
        raise Error("invalid GPU benchmark shape")
    var rng = SplitMix64(UInt64(12345))
    var table = MemTable(dimension)
    for ordinal in range(points):
        table.apply_upsert(
            points - ordinal,
            UInt64(ordinal + 1),
            _uniform_vector(rng, dimension),
        )
    var queries = List[List[Float32]](capacity=batch)
    for _ in range(batch):
        queries.append(_uniform_vector(rng, dimension))
    var config = CollectionConfig.defaults(dimension)
    var sparse = SparseIndex()
    var pins = ArcPointer(GenerationPinRegistry())
    var snapshot = ReadSnapshot.capture(
        config, 1, table.last_sequence, table, sparse, pins
    )
    var options = GpuExecutionOptions(min_work_items=1)
    var expected = execute_exact_batch(table, queries, 10, metric, 0)
    for _ in range(3):
        _same(expected, execute_exact_batch(table, queries, 10, metric, 0))
        _same(expected, _resident(snapshot, queries, metric, options))
    for sample in range(samples):
        var cpu_ns = 0
        var resident_ns = 0
        for phase in range(2):
            var start = perf_counter_ns()
            if (sample + phase) % 2 == 0:
                var result = execute_exact_batch(table, queries, 10, metric, 0)
                cpu_ns = perf_counter_ns() - start
                _same(expected, result)
            else:
                var result = _resident(snapshot, queries, metric, options)
                resident_ns = perf_counter_ns() - start
                _same(expected, result)
        var start = perf_counter_ns()
        var cold = execute_device_batch[True](
            table, queries, 10, metric, options
        )
        var cold_ns = perf_counter_ns() - start
        if not cold.used_gpu:
            raise Error(cold.reason)
        _same(expected, cold.results)
        print(
            "sample points="
            + String(points)
            + " dimension="
            + String(dimension)
            + " batch="
            + String(batch)
            + " metric="
            + String(metric)
            + " ordinal="
            + String(sample)
            + " cpu_ns="
            + String(cpu_ns)
            + " resident_gpu_ns="
            + String(resident_ns)
            + " cold_gpu_ns="
            + String(cold_ns)
        )
    # PROFILE_BEGIN: diagnostic syncs are excluded from the samples above.
    var profile = GpuExecutionOptions(min_work_items=1, profile=True)
    var report = _resident_report(snapshot, queries, metric, profile)
    print(
        "stages metric=" + String(metric) + " cache_hit="
        + String(report.timings.cache_hit)
        + " prepare_ns="
        + String(report.timings.preparation_ns)
        + " allocate_ns="
        + String(report.timings.allocation_ns)
        + " map_upload_ns="
        + String(report.timings.upload_ns)
        + " distance_sync_ns="
        + String(report.timings.distance_ns)
        + " topk_sync_ns="
        + String(report.timings.topk_ns)
        + " readback_ns="
        + String(report.timings.download_ns)
        + " buffers_allocated="
        + String(report.timings.buffer_allocations)
        + " vector_upload_bytes="
        + String(report.timings.vector_upload_bytes)
        + " resident_bytes="
        + String(report.timings.resident_bytes)
    )
    # PROFILE_END
    snapshot.close()
