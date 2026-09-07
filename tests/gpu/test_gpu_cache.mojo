from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
)
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.index.flat import SearchResult
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from max.algorithm import parallelize
from std.math import abs
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def _collection(path: String) raises -> PersistentCollection:
    ensure_directory(path)
    for name in [
        "manifest.bin",
        "wal.bin",
        "sparse.wal",
        "hnsw.cache",
        "metadata.cache",
    ]:
        remove_file_if_exists(path + "/" + name)
    var collection = PersistentCollection.open(path, 3)
    for id in range(1, 41):
        var fields = List[DocumentField]()
        fields.append(DocumentField("keep", PayloadValue.boolean(id % 2 == 0)))
        fields.append(
            DocumentField("group", PayloadValue.integer(Int64(id % 4)))
        )
        fields.append(DocumentField("single", PayloadValue.boolean(id == 7)))
        collection.upsert_document(
            id, [Float32(id), 1.0, Float32(id % 7) + 0.5], fields^
        )
    return collection^


def _same(
    expected: List[List[SearchResult]], actual: List[List[SearchResult]]
) raises:
    assert_equal(len(actual), len(expected))
    for query_index in range(len(expected)):
        assert_equal(len(actual[query_index]), len(expected[query_index]))
        for rank in range(len(expected[query_index])):
            assert_equal(
                actual[query_index][rank].id, expected[query_index][rank].id
            )
            assert_true(
                abs(
                    actual[query_index][rank].score
                    - expected[query_index][rank].score
                )
                < 1.0e-4
            )


def test_collection_gpu_cache_reuses_and_old_snapshot_survives_mutations() raises:
    var collection = _collection("/tmp/akasha-gpu-cache-freshness")
    var queries: List[List[Float32]] = [[1.0, 0.0, 0.0]]
    var options = GpuExecutionOptions(enabled=True, min_work_items=1)
    var first = collection.search_device_dot_batch[True](queries, 3, options)
    var warm = collection.search_device_dot_batch[True](queries, 3, options)
    assert_true(first.used_gpu and warm.used_gpu)
    assert_false(first.timings.cache_hit)
    assert_true(warm.timings.cache_hit)
    assert_equal(warm.timings.buffer_allocations, 0)
    assert_equal(warm.timings.vector_upload_bytes, UInt64(0))
    assert_equal(warm.results[0][0].id, 40)
    var old = collection.snapshot()
    _ = old.search_device_dot_batch[True](queries, 3, options)
    collection.upsert(1, [1000.0, 0.0, 0.0])
    var updated = collection.search_device_dot_batch[True](queries, 3, options)
    assert_true(updated.used_gpu)
    assert_false(updated.timings.cache_hit)
    assert_equal(updated.results[0][0].id, 1)
    assert_equal(updated.timings.sequence, collection.last_sequence())
    var frozen = old.search_device_dot_batch[True](queries, 3, options)
    assert_true(frozen.timings.cache_hit)
    assert_equal(frozen.results[0][0].id, 40)
    collection.delete(1)
    var deleted = collection.search_device_dot_batch[True](queries, 3, options)
    assert_false(deleted.timings.cache_hit)
    assert_equal(deleted.results[0][0].id, 40)
    collection.flush()
    var checkpoint = collection.search_device_dot_batch[True](
        queries, 3, options
    )
    assert_false(checkpoint.timings.cache_hit)
    assert_true(checkpoint.timings.generation > first.timings.generation)
    collection.close()
    var after_close = old.search_device_dot_batch[True](queries, 3, options)
    assert_equal(after_close.results[0][0].id, 40)
    old.close()


def test_ragged_gpu_batch_handles_empty_singleton_and_large_k_for_all_metrics() raises:
    var collection = _collection("/tmp/akasha-gpu-cache-ragged")
    # An excluded zero vector must not make filtered cosine invalid.
    collection.upsert(41, [0.0, 0.0, 0.0])
    var snapshot = collection.snapshot()
    var queries: List[List[Float32]] = [
        [1.0, 2.0, 3.0],
        [3.0, 1.0, 2.0],
        [1.0, 0.0, 1.0],
        [1.0, 1.0, 1.0],
    ]
    var filters = List[FilterExpression]()
    filters.append(
        FilterExpression.condition(
            FilterCondition.equal("keep", PayloadValue.boolean(True))
        )
    )
    filters.append(
        FilterExpression.condition(
            FilterCondition.equal("group", PayloadValue.integer(1))
        )
    )
    filters.append(
        FilterExpression.condition(
            FilterCondition.equal("single", PayloadValue.boolean(True))
        )
    )
    filters.append(
        FilterExpression.condition(
            FilterCondition.equal("missing", PayloadValue.boolean(True))
        )
    )
    var options = GpuExecutionOptions(enabled=True, min_work_items=1)
    for k in [1, 7, 64]:
        var dot = snapshot.search_device_dot_where_batch[True](
            queries, filters, k, options
        )
        var l2 = snapshot.search_device_l2_where_batch[True](
            queries, filters, k, options
        )
        var cosine = snapshot.search_device_cosine_where_batch[True](
            queries, filters, k, options
        )
        assert_true(dot.used_gpu and l2.used_gpu and cosine.used_gpu)
        _same(snapshot.search_dot_where_batch(queries, filters, k), dot.results)
        _same(snapshot.search_l2_where_batch(queries, filters, k), l2.results)
        _same(
            snapshot.search_cosine_where_batch(queries, filters, k),
            cosine.results,
        )
        assert_equal(cosine.stats.distance_evaluations, 31)
        assert_true(cosine.timings.cache_hit)
        assert_equal(cosine.timings.buffer_allocations, 0)
    snapshot.close()
    collection.close()


def test_cache_respects_lower_budget_and_discards_failed_stream() raises:
    var collection = _collection("/tmp/akasha-gpu-cache-budget")
    var snapshot = collection.snapshot()
    var large = List[List[Float32]]()
    for _ in range(64):
        large.append([1.0, 0.0, 0.0])
    var options = GpuExecutionOptions(enabled=True, min_work_items=1)
    var initial = snapshot.search_device_dot_batch[True](large, 10, options)
    assert_true(initial.used_gpu)
    var queries: List[List[Float32]] = [[1.0, 0.0, 0.0]]
    var smaller = snapshot.search_device_dot_batch[True](
        queries,
        3,
        GpuExecutionOptions(
            enabled=True, min_work_items=1, memory_budget_bytes=4096
        ),
    )
    assert_true(smaller.used_gpu and smaller.timings.cache_hit)
    assert_true(smaller.timings.resident_bytes <= UInt64(4096))
    assert_equal(smaller.timings.vector_upload_bytes, UInt64(0))
    var constrained = snapshot.search_device_dot_batch[True](
        queries,
        3,
        GpuExecutionOptions(
            enabled=True, min_work_items=1, memory_budget_bytes=100
        ),
    )
    assert_false(constrained.used_gpu)
    assert_false(Bool(snapshot._gpu_state[].cache))
    var failed = snapshot.search_device_dot_batch[True](
        queries,
        3,
        GpuExecutionOptions(
            enabled=True, min_work_items=1, fail_before_launch=True
        ),
    )
    assert_false(failed.used_gpu)
    var recovered = snapshot.search_device_dot_batch[True](queries, 3, options)
    assert_true(recovered.used_gpu)
    assert_false(recovered.timings.cache_hit)
    _same(snapshot.search_dot_batch(queries, 3), recovered.results)
    snapshot.close()
    collection.close()


def test_concurrent_queries_serialize_shared_snapshot_scratch() raises:
    var collection = _collection("/tmp/akasha-gpu-cache-concurrent")
    var snapshot = collection.snapshot()
    var queries: List[List[Float32]] = [[1.0, 0.0, 0.0]]
    var options = GpuExecutionOptions(enabled=True, min_work_items=1)
    _ = snapshot.search_device_dot_batch[True](queries, 3, options)
    var outputs = List[Int](length=8, fill=0)

    def run_query(
        index: Int,
    ) {imm snapshot, imm queries, imm options, mut outputs}:
        try:
            var actual = snapshot.search_device_dot_batch[True](
                queries, 3, options
            )
            if (
                actual.used_gpu
                and actual.timings.cache_hit
                and actual.timings.buffer_allocations == 0
            ):
                outputs[index] = actual.results[0][0].id
        except:
            outputs[index] = -1

    parallelize(run_query, 8, 4)
    for result in outputs:
        assert_equal(result, 40)
    snapshot.close()
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
