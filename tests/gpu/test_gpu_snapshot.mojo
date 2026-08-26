from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
)
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.math import abs
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def _reset(path: String) raises:
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


def test_real_gpu_snapshot_filtered_batch_matches_cpu() raises:
    var path = String("/tmp/akasha-phase13-gpu-snapshot")
    _reset(path)
    var collection = PersistentCollection.open(path, 3)
    for id in range(1, 41):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField("keep", PayloadValue.boolean(id % 2 == 0))
        )
        collection.upsert_document(
            id,
            [Float32(id), Float32(id % 7) + 0.5, Float32(id % 11)],
            fields^,
        )
    var snapshot = collection.snapshot()
    var queries = List[List[Float32]]()
    queries.append([1.0, 2.0, 3.0])
    queries.append([3.0, 1.0, 2.0])
    var expressions = List[FilterExpression]()
    for _ in range(2):
        expressions.append(
            FilterExpression.condition(
                FilterCondition.equal(
                    "keep", PayloadValue.boolean(True)
                )
            )
        )
    var expected = snapshot.search_cosine_where_batch(
        queries, expressions, 5, num_workers=1
    )
    var actual = snapshot.search_device_cosine_where_batch[
        use_accelerator=True
    ](
        queries,
        expressions,
        5,
        GpuExecutionOptions(min_work_items=1),
    )
    assert_true(actual.used_gpu)
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
                <= 1.0e-5
            )
    snapshot.close()
    collection.close()


def test_real_device_launch_failure_falls_back_to_cpu() raises:
    var path = String("/tmp/akasha-phase13-gpu-snapshot")
    var collection = PersistentCollection.open(path, 3)
    var snapshot = collection.snapshot()
    var queries = List[List[Float32]]()
    queries.append([1.0, 2.0, 3.0])
    var expected = snapshot.search_l2_batch(queries, 4, num_workers=1)
    var actual = snapshot.search_device_l2_batch[use_accelerator=True](
        queries,
        4,
        GpuExecutionOptions(min_work_items=1, fail_before_launch=True),
    )
    assert_false(actual.used_gpu)
    assert_equal(
        actual.reason, "gpu failure: injected GPU launch failure"
    )
    for index in range(4):
        assert_equal(actual.results[0][index].id, expected[0][index].id)
        assert_equal(actual.results[0][index].score, expected[0][index].score)
    snapshot.close()
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
