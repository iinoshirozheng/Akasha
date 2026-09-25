from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    SparseElement,
)
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.query.control import CancellationToken, QueryControl
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from max.algorithm import parallelize
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(path: String) raises:
    ensure_directory(path)
    for name in [
        "manifest.bin",
        "manifest.bin.tmp",
        "wal.bin",
        "wal.bin.tmp",
        "sparse.wal",
        "sparse.wal.tmp",
    ]:
        remove_file_if_exists(path + "/" + name)


def _fields(id: Int) raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("keep", PayloadValue.boolean(id % 2 == 0)))
    return fields^


def _collection(path: String, count: Int) raises -> PersistentCollection:
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    for id in range(count):
        collection.upsert_document(id, [Float32(id), 1.0], _fields(id))
        collection.upsert_sparse(id, [SparseElement(1, Float32(id + 1))])
    return collection^


def _keep() raises -> FilterExpression:
    return FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )


def _is_closed(error: Error, name: String) -> Bool:
    return String(error) == name + " is closed"


def test_acquired_operation_outlives_handle_and_collection_close() raises:
    var collection = _collection("/tmp/akasha-50-operation", 16)
    var snapshot = collection.snapshot()
    var operation = snapshot._acquire()
    snapshot.close()
    snapshot.close()
    with assert_raises(contains="snapshot is closed"):
        _ = snapshot.search_dot([1.0, 0.0], 1)
    with assert_raises(contains="snapshot is closed"):
        _ = snapshot._acquire()
    collection.close()
    collection.close()
    with assert_raises(contains="collection is closed"):
        _ = collection.search_dot([1.0, 0.0], 1)
    # The operation is now the root's last owner; it keeps rows and the pin.
    assert_equal(collection._pins[].active_count(), 1)
    assert_equal(operation[].visible_count, 16)
    assert_true(operation[].find(15)[0] >= 0)
    _ = operation^
    assert_equal(collection._pins[].active_count(), 0)


def test_handle_close_interleaves_with_running_queries() raises:
    var collection = _collection("/tmp/akasha-50-handle-close", 64)
    var snapshot = collection.snapshot()
    collection.close()
    # The handle is the root's only owner, so an unowned borrow would read
    # freed rows once close drops it.
    var failures = List[Int](length=16, fill=0)
    var completed = List[Int](length=16, fill=0)

    def run(task: Int) {mut snapshot, mut failures, mut completed}:
        if task == 0:
            snapshot.close()
            return
        for _ in range(32):
            try:
                var dense = snapshot.search_dot_where([1.0, 0.0], 3, _keep())
                var sparse = snapshot.search_sparse_dot(
                    [SparseElement(1, 1.0)], 1
                )
                var batch = snapshot.search_device_dot_batch[False](
                    [[1.0, 0.0]], 1, GpuExecutionOptions(enabled=True)
                )
                if (
                    dense[0].id != 62
                    or sparse[0].id != 63
                    or batch.results[0][0].id != 63
                ):
                    failures[task] += 1
                completed[task] += 1
            except error:
                if not _is_closed(error, "snapshot"):
                    failures[task] += 1

    parallelize(run, 16, 4)
    for task in range(16):
        assert_equal(failures[task], 0)
    snapshot.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_collection_close_interleaves_with_queries_and_writers() raises:
    var collection = _collection("/tmp/akasha-50-collection-close", 64)
    var failures = List[Int](length=16, fill=0)

    def run(task: Int) {mut collection, mut failures}:
        for round in range(32):
            try:
                if task == 0 and round == 8:
                    collection.close()
                elif task % 4 == 1:
                    var id = 1000 + task * 100 + round
                    collection.upsert_document(id, [-1.0, 0.0], _fields(id))
                    collection.upsert_sparse(id, [SparseElement(2, 1.0)])
                else:
                    var dense = collection.search_dot_where(
                        [1.0, 0.0], 1, _keep()
                    )
                    var sparse = collection.search_sparse_dot(
                        [SparseElement(1, 1.0)], 1
                    )
                    var device = collection.search_device_dot_batch[False](
                        [[1.0, 0.0]], 1, GpuExecutionOptions(enabled=True)
                    )
                    if (
                        dense[0].id != 62
                        or sparse[0].id != 63
                        or device.results[0][0].id != 63
                    ):
                        failures[task] += 1
            except error:
                if not _is_closed(error, "collection"):
                    failures[task] += 1

    parallelize(run, 16, 4)
    for task in range(16):
        assert_equal(failures[task], 0)
    collection.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_worker_errors_release_operation_owners() raises:
    var collection = _collection("/tmp/akasha-50-worker-error", 32)
    var snapshot = collection.snapshot()
    with assert_raises(contains="non-zero"):
        _ = snapshot.search_cosine_parallel([0.0, 0.0], 1, num_workers=4)
    with assert_raises(contains="worker count"):
        _ = snapshot.search_dot_where_parallel(
            [1.0, 0.0], 1, _keep(), num_workers=-1
        )
    var token = CancellationToken()
    token.cancel()
    with assert_raises(contains="cancel"):
        _ = snapshot.search_dot_controlled(
            [1.0, 0.0], 1, QueryControl(token, max_candidates=64)
        )
    with assert_raises(contains="counts must match"):
        _ = snapshot.search_device_dot_where_batch[False](
            [[1.0, 0.0]],
            List[FilterExpression](),
            1,
            GpuExecutionOptions(enabled=True),
        )
    with assert_raises(contains="counts must match"):
        _ = collection.search_device_dot_where_batch[False](
            [[1.0, 0.0]],
            List[FilterExpression](),
            1,
            GpuExecutionOptions(enabled=True),
        )
    # A failed operation leaves the handle usable and owns nothing afterward.
    assert_equal(snapshot.search_dot([1.0, 0.0], 1)[0].id, 31)
    collection.close()
    assert_equal(collection._pins[].active_count(), 1)
    snapshot.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_device_cache_is_root_owned_and_fresh_per_sequence() raises:
    var collection = _collection("/tmp/akasha-50-device-root", 16)
    var first = collection.snapshot()
    var second = collection.snapshot()
    var queries: List[List[Float32]] = [[1.0, 0.0]]
    var options = GpuExecutionOptions(enabled=True)
    assert_equal(
        first.search_device_dot_batch[False](queries, 1, options)
        .results[0][0]
        .id,
        15,
    )
    # Handles of one root share its device state; closing one keeps it.
    var root = second._acquire()
    assert_true(first._acquire()[].device is root[].device)
    assert_true(Bool(root[].device[].table))
    first.close()
    assert_equal(
        collection.search_device_dot_batch[False](queries, 1, options)
        .results[0][0]
        .id,
        15,
    )
    assert_true(collection.snapshot()._acquire()[].device is root[].device)

    # Same generation, newer sequence: a new root and a new device state.
    collection.upsert_document(99, [100.0, 0.0], _fields(99))
    var latest = collection.snapshot()
    assert_equal(latest.generation(), second.generation())
    assert_true(latest.last_sequence() > second.last_sequence())
    assert_equal(
        collection.search_device_dot_batch[False](queries, 1, options)
        .results[0][0]
        .id,
        99,
    )
    var fresh = latest._acquire()
    assert_false(fresh[].device is root[].device)
    assert_equal(fresh[].device[].table.value()[].memtable.live_count(), 17)
    assert_equal(
        second.search_device_dot_batch[False](queries, 1, options)
        .results[0][0]
        .id,
        15,
    )
    _ = root^
    _ = fresh^
    second.close()
    latest.close()
    collection.close()
    assert_equal(collection._pins[].active_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
