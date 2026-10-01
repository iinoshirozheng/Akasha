from akasha import BatchMutation, PersistentCollection
from akasha.index.sparse import SparseElement
from akasha.index.hnsw_rebuild import (
    HNSW_REBUILD_CATCHUP_PASSES,
    HNSW_REBUILD_TAIL_LIMIT,
)
from max.algorithm import parallelize
from std.atomic import Atomic
from std.time import sleep
from std.utils import BlockingScopedLock
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from test_hnsw_rebuild import _config, _reset


def test_rebuild_catches_latest_dense_states_across_flush_and_batch() raises:
    var path = String("/tmp/akasha-rebuild-catchup")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    for id in range(16):
        collection.upsert(id, [Float32(id)])
    var job = collection._begin_hnsw_rebuild()
    var candidate = job[].build()
    collection.upsert(1, [101.0])
    collection.delete(2)
    collection.delete(3)
    collection.flush()
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.upsert(3, [103.0]))
    mutations.append(BatchMutation.upsert(4, [104.0]))
    mutations.append(BatchMutation.delete(4))
    mutations.append(BatchMutation.upsert(4, [204.0]))
    mutations.append(BatchMutation.upsert(30, [130.0]))
    _ = collection.apply_batch(mutations)
    collection.upsert_sparse(1, [SparseElement(1, 1.0)])

    assert_true(collection._finish_hnsw_rebuild(job, candidate^))
    assert_true(collection.hnsw_available())
    collection._hnsw.validate_structure()
    assert_equal(collection._hnsw.current_point_count(), 16)
    assert_false(collection._hnsw.contains_current(2))
    for query in [Float32(101.0), 103.0, 204.0, 130.0]:
        var exact = collection.search_l2([query], 16)
        var approximate = collection.search_l2_approx([query], 16, 128)
        assert_equal(len(exact), len(approximate))
        for index in range(len(exact)):
            assert_equal(approximate[index].id, exact[index].id)
            assert_equal(approximate[index].score, exact[index].score)
    collection.close()
    var reopened = PersistentCollection.open_with_config(path, _config())
    assert_equal(reopened.last_sequence(), UInt64(25))
    assert_false(reopened._hnsw.contains_current(2))
    assert_equal(reopened.search_l2_approx([204.0], 1, 128)[0].id, 4)
    reopened.flush()
    reopened.close()
    var checkpointed = PersistentCollection.open_with_config(path, _config())
    assert_equal(checkpointed._hnsw.current_point_count(), 16)
    assert_equal(checkpointed.search_l2_approx([130.0], 1, 128)[0].id, 30)
    checkpointed.close()


def test_stale_config_cannot_replace_current_graph() raises:
    var path = String("/tmp/akasha-rebuild-stale-config")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(1, [1.0])
    var job = collection._begin_hnsw_rebuild()
    var candidate = job[].build()
    collection._config.level_seed += 1
    assert_false(collection._finish_hnsw_rebuild(job, candidate^))
    assert_equal(collection.get(1).value().vector[0], Float32(1.0))
    collection.close()


def test_overflow_discards_candidate_then_new_capture_covers_all_writes() raises:
    var path = String("/tmp/akasha-rebuild-overflow")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [0.0])
    var job = collection._begin_hnsw_rebuild()
    var candidate = job[].build()
    var batch = List[BatchMutation]()
    for id in range(1, HNSW_REBUILD_TAIL_LIMIT + 2):
        batch.append(BatchMutation.upsert(id, [Float32(id)]))
    _ = collection.apply_batch(batch)
    assert_true(job[].invalid)
    assert_equal(job[].tail.slot_count(), HNSW_REBUILD_TAIL_LIMIT)
    assert_false(collection._finish_hnsw_rebuild(job, candidate^))
    assert_true(collection.hnsw_available())
    collection.rebuild_hnsw()
    assert_equal(
        collection._hnsw.current_point_count(), HNSW_REBUILD_TAIL_LIMIT + 2
    )
    assert_equal(collection.search_l2_approx([1025.0], 1, 128)[0].id, 1025)
    collection.close()


def test_repeated_ids_and_sparse_only_writes_do_not_fill_journal() raises:
    var path = String("/tmp/akasha-rebuild-journal-bound")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [0.0])
    var job = collection._begin_hnsw_rebuild()
    collection.upsert_sparse(0, [SparseElement(1, 1.0)])
    assert_equal(job[].tail.slot_count(), 0)
    var batch = List[BatchMutation]()
    for i in range(HNSW_REBUILD_TAIL_LIMIT + 2):
        batch.append(BatchMutation.upsert(0, [Float32(i)]))
    _ = collection.apply_batch(batch)
    assert_false(job[].invalid)
    assert_equal(job[].tail.slot_count(), 1)
    assert_equal(
        job[].tail.entry_ref_at(0).dense_address(),
        collection._memtable.entry_ref_at(0).dense_address(),
    )
    var candidate = job[].build()
    assert_true(collection._finish_hnsw_rebuild(job, candidate^))
    assert_equal(
        collection.search_l2_approx([1025.0], 1, 128)[0].score, Float32(0.0)
    )
    collection.close()


def test_build_failure_keeps_current_graph_and_clears_job() raises:
    var path = String("/tmp/akasha-rebuild-build-failure")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [42.0])
    var job = collection._begin_hnsw_rebuild()
    # Inject a bad build config on this immutable test input only.
    var original_m = job[].root[].config.m
    job[].root[].config.m = 0
    var failed = False
    try:
        _ = job[].build()
    except:
        failed = True
    job[].root[].config.m = original_m
    collection._cancel_hnsw_rebuild(job)
    assert_true(failed)
    assert_true(collection.hnsw_available())
    assert_false(Bool(collection._hnsw_rebuild))
    assert_equal(collection.search_l2_approx([42.0], 1, 16)[0].id, 0)
    collection.rebuild_hnsw()
    collection.close()


def test_close_keeps_build_input_alive_but_rejects_publication() raises:
    var path = String("/tmp/akasha-rebuild-close")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [42.0])
    var job = collection._begin_hnsw_rebuild()
    collection.close()
    var candidate = job[].build()
    assert_equal(candidate.current_point_count(), 1)
    var closed = False
    try:
        _ = collection._finish_hnsw_rebuild(job, candidate^)
    except error:
        closed = String(error) == "collection is closed"
    assert_true(closed)
    assert_false(Bool(collection._hnsw_rebuild))


def test_catchup_failure_preserves_ready_graph() raises:
    var path = String("/tmp/akasha-rebuild-catchup-failure")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [0.0])
    var job = collection._begin_hnsw_rebuild()
    var candidate = job[].build()
    collection.upsert(0, [42.0])
    candidate._delta.config.dimension = 2
    var failed = False
    try:
        _ = collection._finish_hnsw_rebuild(job, candidate^)
    except:
        failed = True
    assert_true(failed)
    assert_true(collection.hnsw_available())
    assert_false(Bool(collection._hnsw_rebuild))
    assert_equal(
        collection.search_l2_approx([42.0], 1, 16)[0].score, Float32(0.0)
    )
    collection.close()


def test_unavailable_graph_still_records_every_batch_state() raises:
    var path = String("/tmp/akasha-rebuild-unavailable-batch")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [0.0])
    var job = collection._begin_hnsw_rebuild()
    var candidate = job[].build()
    collection._hnsw._delta.config.dimension = 2
    collection.upsert(0, [42.0])
    assert_false(collection.hnsw_available())
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.delete(0))
    mutations.append(BatchMutation.upsert(1, [1.0]))
    mutations.append(BatchMutation.upsert(2, [2.0]))
    _ = collection.apply_batch(mutations)
    assert_equal(job[].tail.slot_count(), 3)
    assert_true(collection._finish_hnsw_rebuild(job, candidate^))
    assert_true(collection.hnsw_available())
    assert_false(collection._hnsw.contains_current(0))
    assert_equal(collection._hnsw.current_point_count(), 2)
    collection._hnsw.validate_structure()
    collection.close()


def test_missing_coverage_and_stale_jobs_cannot_publish() raises:
    var path = String("/tmp/akasha-rebuild-missing-coverage")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [0.0])
    var old_job = collection._begin_hnsw_rebuild()
    var old_candidate = old_job[].build()
    collection._cancel_hnsw_rebuild(old_job)
    var job = collection._begin_hnsw_rebuild()
    assert_false(collection._finish_hnsw_rebuild(old_job, old_candidate^))
    assert_true(collection._hnsw_rebuild.value() is job)
    collection.upsert(0, [42.0])
    var candidate = job[].build()
    job[].sequence -= 1
    assert_false(collection._finish_hnsw_rebuild(job, candidate^))
    assert_equal(
        collection.search_l2_approx([42.0], 1, 16)[0].score, Float32(0.0)
    )
    collection.close()


def _assert_public_retry(exhaust: Bool) raises:
    var path = String("/tmp/akasha-rebuild-public-retry-") + String(exhaust)
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [0.0])
    collection._hnsw_rebuild_delay_for_test = 0.1
    var failures = Atomic[DType.int64](0)
    var exhausted = Atomic[DType.int64](0)

    def rebuild_or_overflow(
        task: Int,
    ) {mut collection, mut failures, mut exhausted, exhaust}:
        try:
            if task == 0:
                try:
                    collection.rebuild_hnsw()
                except error:
                    if String(error) == "HNSW rebuild retry budget exhausted":
                        exhausted.store(1)
                    else:
                        raise error^
                return
            var previous = UInt64.MAX
            for _ in range(4 if exhaust else 1):
                var observed = False
                for _ in range(2_000):
                    with BlockingScopedLock(collection._writer_lock[]):
                        if collection._hnsw_rebuild:
                            var sequence = (
                                collection._hnsw_rebuild.value()[]
                                .root[]
                                .sequence
                            )
                            if sequence != previous:
                                previous = sequence
                                observed = True
                    if observed:
                        break
                    sleep(0.001)
                if not observed:
                    _ = failures.fetch_add(1)
                    return
                var mutations = List[BatchMutation]()
                for id in range(1, HNSW_REBUILD_TAIL_LIMIT + 2):
                    mutations.append(BatchMutation.upsert(id, [Float32(id)]))
                _ = collection.apply_batch(mutations)
        except:
            _ = failures.fetch_add(1)

    parallelize(rebuild_or_overflow, 2, 2)
    assert_equal(failures.load(), 0)
    assert_equal(exhausted.load(), Int64(Int(exhaust)))
    assert_false(Bool(collection._hnsw_rebuild))
    assert_true(collection.hnsw_available())
    assert_equal(
        collection._hnsw.current_point_count(), HNSW_REBUILD_TAIL_LIMIT + 2
    )
    assert_equal(collection.search_l2_approx([1025.0], 1, 128)[0].id, 1025)
    collection.close()


def test_public_rebuild_retries_overflowed_capture() raises:
    _assert_public_retry(False)


def test_public_rebuild_stops_at_retry_budget_without_losing_graph() raises:
    _assert_public_retry(True)


def _assert_writer_during_build(operation: Int) raises:
    var path = String("/tmp/akasha-rebuild-public-writer-") + String(operation)
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [0.0])
    if operation > 0:
        collection.rebuild_hnsw()
        collection.upsert(0, [42.0])
        assert_true(collection._hnsw_requires_maintenance())
    collection._hnsw_rebuild_delay_for_test = 0.2
    var failures = Atomic[DType.int64](0)
    var written_during_build = Atomic[DType.int64](0)

    def rebuild_or_write(
        task: Int,
    ) {mut collection, mut failures, mut written_during_build, operation}:
        try:
            if task == 0:
                if operation == 1:
                    collection.flush()
                elif operation == 2:
                    collection.compact()
                elif operation == 3:
                    _ = collection.maintenance()
                elif operation == 4:
                    var checkpoint = collection._begin_backup()
                    collection._end_backup(checkpoint)
                else:
                    collection.rebuild_hnsw()
                return
            for _ in range(2_000):
                var building: Bool
                with BlockingScopedLock(collection._writer_lock[]):
                    building = Bool(collection._hnsw_rebuild)
                if building:
                    collection.upsert(1, [101.0])
                    with BlockingScopedLock(collection._writer_lock[]):
                        if collection._hnsw_rebuild:
                            written_during_build.store(1)
                    return
                sleep(0.001)
            _ = failures.fetch_add(1)
        except:
            _ = failures.fetch_add(1)

    parallelize(rebuild_or_write, 2, 2)
    assert_equal(failures.load(), 0)
    assert_equal(written_during_build.load(), 1)
    assert_equal(collection.search_l2_approx([101.0], 1, 16)[0].id, 1)
    collection._hnsw.validate_structure()
    collection.close()


def test_public_rebuild_allows_writer_during_build() raises:
    _assert_writer_during_build(0)


def test_flush_triggered_rebuild_allows_writer_during_build() raises:
    _assert_writer_during_build(1)


def test_compaction_checkpoint_allows_writer_during_rebuild() raises:
    _assert_writer_during_build(2)


def test_maintenance_checkpoint_allows_writer_during_rebuild() raises:
    _assert_writer_during_build(3)


def test_backup_checkpoint_allows_writer_during_rebuild() raises:
    _assert_writer_during_build(4)


def test_writer_can_update_same_id_during_detached_catchup() raises:
    var path = String("/tmp/akasha-rebuild-detached-catchup")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [0.0])
    var job = collection._begin_hnsw_rebuild()
    collection.upsert(0, [42.0])
    job[].catchup_delay_for_test = 0.2
    var failures = Atomic[DType.int64](0)
    var wrote_during_catchup = Atomic[DType.int64](0)

    def catchup_or_write(
        task: Int,
    ) {mut collection, job, mut failures, mut wrote_during_catchup}:
        try:
            if task == 0:
                var candidate = job[].build()
                if not collection._finish_hnsw_rebuild(job, candidate^):
                    _ = failures.fetch_add(1)
                return
            for _ in range(2_000):
                if job[].catchup_started_for_test[].load() > 0:
                    collection.upsert(0, [101.0])
                    collection.upsert_sparse(0, [SparseElement(2, 2.0)])
                    with BlockingScopedLock(collection._writer_lock[]):
                        if collection._hnsw_rebuild:
                            wrote_during_catchup.store(1)
                    return
                sleep(0.001)
            _ = failures.fetch_add(1)
        except:
            _ = failures.fetch_add(1)

    parallelize(catchup_or_write, 2, 2)
    assert_equal(failures.load(), 0)
    assert_equal(wrote_during_catchup.load(), 1)
    assert_equal(
        collection.search_l2_approx([101.0], 1, 16)[0].score, Float32(0.0)
    )
    assert_equal(collection._hnsw.mutation_count(), 2)
    collection._hnsw.validate_structure()
    collection.close()


def test_continuous_writes_stop_at_catchup_pass_budget() raises:
    var path = String("/tmp/akasha-rebuild-catchup-budget")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(0, [0.0])
    var job = collection._begin_hnsw_rebuild()
    collection.upsert(0, [42.0])
    job[].catchup_delay_for_test = 0.2
    var failures = Atomic[DType.int64](0)
    var rejected = Atomic[DType.int64](0)

    def catchup_or_write(
        task: Int,
    ) {mut collection, job, mut failures, mut rejected}:
        try:
            if task == 0:
                var candidate = job[].build()
                if not collection._finish_hnsw_rebuild(job, candidate^):
                    rejected.store(1)
                return
            for update in range(1, HNSW_REBUILD_CATCHUP_PASSES + 1):
                var observed = False
                for _ in range(2_000):
                    if job[].catchup_started_for_test[].load() == Int64(update):
                        collection.upsert(0, [Float32(update)])
                        observed = True
                        break
                    sleep(0.001)
                if not observed:
                    _ = failures.fetch_add(1)
                    return
        except:
            _ = failures.fetch_add(1)

    parallelize(catchup_or_write, 2, 2)
    assert_equal(failures.load(), 0)
    assert_equal(rejected.load(), 1)
    assert_false(Bool(collection._hnsw_rebuild))
    assert_true(collection.hnsw_available())
    assert_equal(
        collection.search_l2_approx([4.0], 1, 16)[0].score, Float32(0.0)
    )
    collection.rebuild_hnsw()
    assert_equal(collection.hnsw_inactive_count(), 0)
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
