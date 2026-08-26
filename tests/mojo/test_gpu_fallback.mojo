from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
)
from akasha.compute.gpu.flat_scan import execute_device_batch
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.query.batch_executor import (
    BATCH_COSINE_METRIC,
    BATCH_DOT_METRIC,
    BATCH_L2_METRIC,
    execute_exact_batch,
)
from akasha.storage.memtable import MemTable
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_false, assert_raises, TestSuite


def _table() raises -> MemTable:
    var table = MemTable(3)
    for id in range(1, 33):
        table.apply_upsert(
            id,
            UInt64(id),
            [Float32(id), Float32(id % 5) + 1.0, Float32(id % 7)],
        )
    return table^


def test_compile_time_disabled_device_path_matches_cpu_all_metrics() raises:
    var table = _table()
    var queries = List[List[Float32]]()
    queries.append([1.0, 2.0, 3.0])
    queries.append([3.0, 1.0, 0.5])
    for metric in [BATCH_DOT_METRIC, BATCH_L2_METRIC, BATCH_COSINE_METRIC]:
        var expected = execute_exact_batch(table, queries, 5, metric, 1)
        var actual = execute_device_batch[use_accelerator=False](
            table, queries, 5, metric, GpuExecutionOptions(min_work_items=1)
        )
        assert_false(actual.used_gpu)
        assert_equal(actual.reason, "no accelerator")
        for query_index in range(len(expected)):
            for result_index in range(len(expected[query_index])):
                assert_equal(
                    actual.results[query_index][result_index].id,
                    expected[query_index][result_index].id,
                )
                assert_equal(
                    actual.results[query_index][result_index].score,
                    expected[query_index][result_index].score,
                )


def test_disabled_option_reports_reason_and_preserves_empty_batch() raises:
    var table = _table()
    var queries = List[List[Float32]]()
    var result = execute_device_batch[use_accelerator=False](
        table,
        queries,
        3,
        BATCH_DOT_METRIC,
        GpuExecutionOptions(enabled=False),
    )
    assert_false(result.used_gpu)
    assert_equal(result.reason, "disabled")
    assert_equal(len(result.results), 0)


def test_snapshot_device_fallback_preserves_filtered_results_and_close() raises:
    var path = String("/tmp/akasha-phase13-device-fallback")
    ensure_directory(path)
    for name in [
        "manifest.bin",
        "manifest.bin.tmp",
        "wal.bin",
        "wal.bin.tmp",
        "sparse.wal",
        "sparse.wal.tmp",
        "hnsw.cache",
        "metadata.cache",
    ]:
        remove_file_if_exists(path + "/" + name)
    var collection = PersistentCollection.open(path, 2)
    for id in range(1, 7):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField("keep", PayloadValue.boolean(id % 2 == 0))
        )
        collection.upsert_document(
            id, [Float32(id), Float32(id % 3) + 1.0], fields^
        )
    var snapshot = collection.snapshot()
    var queries = List[List[Float32]]()
    queries.append([1.0, 0.0])
    var expression = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    var expressions = List[FilterExpression]()
    expressions.append(expression^)
    var result = snapshot.search_device_dot_where_batch[
        use_accelerator=False
    ](queries, expressions, 2, GpuExecutionOptions(min_work_items=1))
    assert_false(result.used_gpu)
    assert_equal(result.results[0][0].id, 6)
    assert_equal(result.results[0][1].id, 4)
    snapshot.close()
    with assert_raises():
        _ = snapshot.search_device_dot_batch[use_accelerator=False](
            queries, 1, GpuExecutionOptions()
        )
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
