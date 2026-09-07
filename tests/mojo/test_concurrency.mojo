from akasha import (
    BatchMutation,
    CollectionConfig,
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
)
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from max.algorithm import parallelize
from std.atomic import Atomic
from std.testing import assert_equal, assert_true, TestSuite


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/sparse.wal")
    remove_file_if_exists(directory + "/sparse.wal.tmp")


def _ann_collection(path: String) raises -> PersistentCollection:
    _reset(path)
    var config = CollectionConfig.defaults(1)
    config.rebuild_inactive_percent = 1
    config.delta_max_points = 1
    var collection = PersistentCollection.open_with_config(path, config)
    for id in range(128):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField("keep", PayloadValue.boolean(id % 2 == 0))
        )
        collection.upsert_document(id, [Float32(id + 1)], fields^)
    return collection^


def _run_ann_entrypoint(
    mut collection: PersistentCollection, operation: Int
) raises -> Int:
    var expression = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    if operation == 0:
        return collection.search_dot_approx([1.0], 1, 64)[0].id
    if operation == 1:
        return collection.search_l2_approx([128.0], 1, 64)[0].id
    if operation == 2:
        return collection.search_cosine_approx([1.0], 1, 64)[0].id
    if operation == 3:
        return collection.search_dot_approx_where(
            [1.0], 1, 64, expression
        )[0].id
    if operation == 4:
        return collection.search_l2_approx_where(
            [128.0], 1, 64, expression
        )[0].id
    return collection.search_cosine_approx_where(
        [1.0], 1, 64, expression
    )[0].id


def _valid_ann_result(operation: Int, id: Int) -> Bool:
    if operation == 0 or operation == 1:
        return id == 127
    if operation == 2 or operation == 5:
        return id == 0
    return id == 126


def test_concurrent_batch_writers_serialize_sequence_and_recovery() raises:
    var path = String("/tmp/akasha-phase11-concurrent-writers")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var failures = Atomic[DType.int64](0)

    def write_batch(worker: Int) {mut collection, mut failures}:
        try:
            var mutations = List[BatchMutation]()
            for offset in range(4):
                var id = worker * 100 + offset
                mutations.append(BatchMutation.upsert(id, [Float32(id + 1)]))
            _ = collection.apply_batch(mutations)
        except:
            _ = failures.fetch_add(1)

    parallelize(write_batch, 8, 4)

    assert_equal(failures.load(), 0)
    assert_equal(collection.last_sequence(), UInt64(32))
    assert_equal(collection.metadata_live_count(), 32)
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.last_sequence(), UInt64(32))
    assert_equal(reopened.metadata_live_count(), 32)
    reopened.close()


def test_concurrent_snapshot_capture_observes_only_batch_boundaries() raises:
    var path = String("/tmp/akasha-phase11-concurrent-snapshots")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var failures = Atomic[DType.int64](0)
    var sequences = List[UInt64](length=4, fill=0)
    var counts = List[Int](length=4, fill=0)

    def write_or_snapshot(
        task: Int,
    ) {mut collection, mut failures, mut sequences, mut counts}:
        try:
            if task < 4:
                var mutations = List[BatchMutation]()
                for offset in range(4):
                    var id = task * 100 + offset
                    mutations.append(
                        BatchMutation.upsert(id, [Float32(id + 1)])
                    )
                _ = collection.apply_batch(mutations)
                return
            var snapshot_index = task - 4
            var snapshot = collection.snapshot()
            sequences[snapshot_index] = snapshot.last_sequence()
            counts[snapshot_index] = len(snapshot.search_dot([1.0], 64))
            snapshot.close()
        except:
            _ = failures.fetch_add(1)

    parallelize(write_or_snapshot, 8, 4)

    assert_equal(failures.load(), 0)
    assert_equal(collection.last_sequence(), UInt64(16))
    for index in range(4):
        assert_equal(sequences[index] % 4, UInt64(0))
        assert_equal(UInt64(counts[index]), sequences[index])
    collection.close()


def test_all_ann_entrypoints_serialize_shared_graph_query_state() raises:
    var collection = _ann_collection(
        "/tmp/akasha-task19-concurrent-ann-entrypoints"
    )
    collection.rebuild_hnsw()
    var failures = Atomic[DType.int64](0)
    for operation in range(6):
        assert_true(
            _valid_ann_result(
                operation, _run_ann_entrypoint(collection, operation)
            )
        )

    def query_many(task: Int) {mut collection, mut failures}:
        try:
            for iteration in range(8):
                var operation = (task + iteration) % 6
                var id = _run_ann_entrypoint(collection, operation)
                if not _valid_ann_result(operation, id):
                    _ = failures.fetch_add(1)
        except:
            _ = failures.fetch_add(1)

    parallelize(query_many, 12, 4)

    assert_equal(failures.load(), 0)
    assert_equal(_run_ann_entrypoint(collection, 1), 127)
    collection.close()


def test_ann_queries_serialize_with_explicit_rebuild_and_release_lock() raises:
    var collection = _ann_collection(
        "/tmp/akasha-task19-concurrent-ann-rebuild"
    )
    collection.rebuild_hnsw()
    var failures = Atomic[DType.int64](0)

    def query_or_rebuild(task: Int) {mut collection, mut failures}:
        try:
            if task == 0:
                for _ in range(4):
                    collection.rebuild_hnsw()
                return
            for iteration in range(8):
                var operation = (task + iteration) % 6
                var id = _run_ann_entrypoint(collection, operation)
                if not _valid_ann_result(operation, id):
                    _ = failures.fetch_add(1)
        except:
            _ = failures.fetch_add(1)

    parallelize(query_or_rebuild, 9, 4)

    assert_equal(failures.load(), 0)
    collection.upsert(128, [129.0])
    assert_equal(collection.search_l2_approx([129.0], 1, 64)[0].id, 128)
    collection.close()


def test_ann_queries_serialize_with_flush_rebuild_and_release_lock() raises:
    var collection = _ann_collection(
        "/tmp/akasha-task19-concurrent-ann-flush"
    )
    var failures = Atomic[DType.int64](0)

    def query_or_flush(task: Int) {mut collection, mut failures}:
        try:
            if task == 0:
                for iteration in range(4):
                    collection.upsert(127, [Float32(127 + iteration)])
                    collection.flush()
                return
            for iteration in range(8):
                var operation = (task + iteration) % 6
                var id = _run_ann_entrypoint(collection, operation)
                if (operation == 0 or operation == 1) and id not in [126, 127]:
                    _ = failures.fetch_add(1)
                elif (
                    operation != 0
                    and operation != 1
                    and not _valid_ann_result(operation, id)
                ):
                    _ = failures.fetch_add(1)
        except:
            _ = failures.fetch_add(1)

    parallelize(query_or_flush, 9, 4)

    assert_equal(failures.load(), 0)
    collection.rebuild_hnsw()
    assert_true(collection.hnsw_available())
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
