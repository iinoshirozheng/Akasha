from akasha import BatchMutation, PersistentCollection, SparseElement
from akasha.common.config import CollectionConfig
from akasha.storage.compaction import CompactionPolicy, LEVEL_ZERO_SEGMENT_LIMIT
from akasha.storage.committed_compaction import (
    begin_compaction,
    build_compaction,
    COMPACTION_ATTEMPTS,
    CompactionInputs,
)
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.manifest import load_manifest
from akasha.storage.memtable import MemTable
from akasha.storage.read_generation import (
    HEAD_MAX_POINTS,
    MAX_SEALED_RUNS,
    ReadGenerationCache,
    SEALED_RUN_LIMIT,
)
from max.algorithm import parallelize
from std.atomic import Atomic
from std.ffi import c_int, external_call
from std.memory import ArcPointer
from std.os import listdir
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from std.time import perf_counter_ns, sleep
from std.utils import BlockingScopedLock


comptime _DIMENSION = 64
comptime _PART = 8000
"""Points per committed segment; three make a merge of tens of milliseconds."""
comptime _WAIT_NS = 30_000_000_000


def _reset(path: String) raises:
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)


def _job_outputs(path: String) raises -> List[String]:
    var outputs = List[String]()
    for name in listdir(path):
        if name.startswith("segment-compact-") or name.startswith(
            "sparse-compact-"
        ):
            outputs.append(name)
    return outputs^


def _set_mode(path: String, mode: Int) raises:
    var owned_path = path
    var result = external_call["chmod", c_int](
        owned_path.as_c_string_slice().unsafe_ptr(), c_int(mode)
    )
    if result != 0:
        raise Error("chmod failed")


def _cheap_config(dimension: Int) -> CollectionConfig:
    """Keep HNSW inserts cheap so tests spend their time in compaction."""
    var config = CollectionConfig.defaults(dimension)
    config.m = 2
    config.m0 = 2
    config.ef_construction = 2
    return config^


def _vector(id: Int, dimension: Int) -> List[Float32]:
    var values = List[Float32](capacity=dimension)
    values.append(Float32(id))
    for index in range(1, dimension):
        values.append(Float32((id * 31 + index * 7) % 97) / 97.0)
    return values^


def _batch(first: Int, count: Int, dimension: Int) -> List[BatchMutation]:
    var mutations = List[BatchMutation](capacity=count)
    for id in range(first, first + count):
        mutations.append(BatchMutation.upsert(id, _vector(id, dimension)))
    return mutations^


def _slow_collection(path: String) raises -> PersistentCollection:
    """Commit three large segments; merging them takes tens of milliseconds."""
    _reset(path)
    var collection = PersistentCollection.open_with_config(
        path, _cheap_config(_DIMENSION)
    )
    assert_true(collection.background_maintenance_enabled())
    for part in range(3):
        _ = collection.apply_batch(_batch(part * _PART, _PART, _DIMENSION))
        collection.flush()
    assert_equal(len(load_manifest(path, _DIMENSION).segments), 3)
    return collection^


def _small_collection(path: String) raises -> PersistentCollection:
    """Open a worker-backed collection whose publisher already has a base."""
    _reset(path)
    var collection = PersistentCollection.open_with_config(
        path, _cheap_config(4)
    )
    assert_true(collection.background_maintenance_enabled())
    var base = collection.snapshot()
    base.close()
    return collection^


def _await_job_pin(collection: PersistentCollection) raises:
    """Wait until a background job holds its input pin."""
    var start = perf_counter_ns()
    while collection._pins[].active_count() == 0:
        if perf_counter_ns() - start > _WAIT_NS:
            raise Error("background job never pinned its inputs")
        sleep(0.0005)


def _await_attempts(mut collection: PersistentCollection, count: Int) raises:
    var start = perf_counter_ns()
    while collection.background_compaction_counts().attempts < count:
        if perf_counter_ns() - start > _WAIT_NS:
            raise Error("background compaction never started")
        sleep(0.0005)


def _assert_slow_records(
    collection: PersistentCollection, extra: List[Int]
) raises:
    for id in range(0, 3 * _PART, 997):
        assert_equal(collection.get(id).value().vector[0], Float32(id))
    for id in extra:
        assert_equal(collection.get(id).value().vector[0], Float32(id))


def test_worker_builds_without_the_writer_lock() raises:
    var path = String("/tmp/akasha-52-worker-unlocked-build")
    var collection = _slow_collection(path)
    assert_true(collection.schedule_maintenance())
    _await_job_pin(collection)

    # The job pin spans the build; this write completes inside it.
    collection.upsert(90_001, _vector(90_001, _DIMENSION))
    assert_true(collection._pins[].active_count() > 0)

    assert_true(collection.wait_for_maintenance())
    var manifest = load_manifest(path, _DIMENSION)
    assert_equal(len(manifest.segments), 1)
    assert_true(manifest.segments[0].name.startswith("segment-compact-"))
    var counts = collection.background_compaction_counts()
    assert_equal(counts.attempts, 1)
    assert_equal(counts.conflicts, 0)
    assert_equal(counts.exhausted, 0)
    assert_equal(collection._pins[].active_count(), 0)
    _assert_slow_records(collection, [90_001])
    collection.close()

    var reopened = PersistentCollection.open_with_config(
        path, _cheap_config(_DIMENSION)
    )
    _assert_slow_records(reopened, [90_001])
    reopened.close()


def test_foreground_and_worker_on_the_same_inputs_publish_once() raises:
    var path = String("/tmp/akasha-52-worker-foreground-race")
    var collection = _slow_collection(path)
    var captured = load_manifest(path, _DIMENSION)
    assert_true(collection.schedule_maintenance())
    _await_job_pin(collection)

    # While the worker still holds its pin it has not published, so this
    # foreground job captures the same inputs.
    var job: Optional[CompactionInputs]
    with BlockingScopedLock(collection._writer_lock[]):
        assert_true(collection._pins[].active_count() > 0)
        job = begin_compaction(path, _DIMENSION, collection._pins)
    assert_equal(job.value().manifest.generation, captured.generation)
    var output = build_compaction(
        path, _DIMENSION, job.value(), collection._pins
    )
    var foreground_won = collection._finish_compaction(job.value(), output)
    assert_true(collection.wait_for_maintenance())

    var counts = collection.background_compaction_counts()
    assert_equal(counts.attempts, 1)
    assert_equal(counts.conflicts + collection.compaction_conflicts(), 1)
    assert_equal(counts.conflicts, 1 if foreground_won else 0)
    var published = load_manifest(path, _DIMENSION)
    assert_equal(published.generation, captured.generation + 1)
    assert_equal(len(published.segments), 1)
    # The loser discarded its files and overwrote nothing.
    var outputs = _job_outputs(path)
    assert_equal(len(outputs), 2)
    assert_true(
        (published.segments[0].name == output.segment_name) == foreground_won
    )
    # The loser's pin queued the inputs; the next checkpoint reclaims them.
    for index in range(len(captured.segments)):
        assert_true(path_exists(path + "/" + captured.segments[index].name))
    collection.flush()
    for index in range(len(captured.segments)):
        assert_false(path_exists(path + "/" + captured.segments[index].name))
    _assert_slow_records(collection, [])
    collection.close()


def test_public_compact_does_not_compete_with_running_worker() raises:
    var path = String("/tmp/akasha-compaction-exclusive-public")
    var collection = _slow_collection(path)
    collection._maintenance._state[].compaction_delay_for_test = 0.3
    assert_true(collection.schedule_maintenance())
    _await_attempts(collection, 1)
    # The worker has captured its inputs. Foreground compaction must wait
    # without the writer lock; its checkpoint includes this accepted write.
    collection.upsert(90_003, _vector(90_003, _DIMENSION))
    collection.compact()
    assert_true(collection.wait_for_maintenance())
    var counts = collection.background_compaction_counts()
    assert_equal(counts.conflicts + collection.compaction_conflicts(), 0)
    assert_equal(counts.exhausted, 0)
    assert_equal(counts.attempts, 1)
    assert_equal(collection.compaction_attempts(), 1)
    _assert_slow_records(collection, [90_003])
    collection.close()
    var reopened = PersistentCollection.open_with_config(
        path, _cheap_config(_DIMENSION)
    )
    _assert_slow_records(reopened, [90_003])
    reopened.close()


def test_worker_checksum_failure_keeps_old_generation() raises:
    var path = String("/tmp/akasha-52-worker-checksum")
    var collection = _slow_collection(path)
    var manifest_bytes = read_file_bytes(path + "/manifest.bin")
    var captured = load_manifest(path, _DIMENSION)
    var victim = path + "/" + captured.segments[1].name
    var original = read_file_bytes(victim)
    var corrupted = original.copy()
    corrupted[len(corrupted) // 2] ^= 0xFF
    write_file_sync(victim, corrupted)

    assert_true(collection.schedule_maintenance())
    with assert_raises(contains="background maintenance failed"):
        _ = collection.wait_for_maintenance()

    assert_true(read_file_bytes(path + "/manifest.bin") == manifest_bytes)
    assert_equal(len(_job_outputs(path)), 0)
    assert_equal(collection._pins[].active_count(), 0)
    # The first error stays reported; nothing else runs.
    with assert_raises(contains="mismatch"):
        _ = collection.get(0)
    with assert_raises(contains="background maintenance failed"):
        collection.upsert(90_001, _vector(90_001, _DIMENSION))
    with assert_raises(contains="background maintenance failed"):
        collection.close()

    write_file_sync(victim, original)
    var reopened = PersistentCollection.open_with_config(
        path, _cheap_config(_DIMENSION)
    )
    assert_equal(
        load_manifest(path, _DIMENSION).generation, captured.generation
    )
    _assert_slow_records(reopened, [])
    reopened.close()


def test_worker_output_io_failure_keeps_old_generation() raises:
    var path = String("/tmp/akasha-52-worker-io")
    var collection = _slow_collection(path)
    var manifest_bytes = read_file_bytes(path + "/manifest.bin")

    _set_mode(path, 0o555)
    var failed = False
    try:
        _ = collection.schedule_maintenance()
        _ = collection.wait_for_maintenance()
    except:
        failed = True
    _set_mode(path, 0o755)

    assert_true(failed)
    assert_true(read_file_bytes(path + "/manifest.bin") == manifest_bytes)
    assert_equal(len(_job_outputs(path)), 0)
    assert_equal(collection._pins[].active_count(), 0)
    with assert_raises(contains="background maintenance failed"):
        collection.close()

    var reopened = PersistentCollection.open_with_config(
        path, _cheap_config(_DIMENSION)
    )
    _assert_slow_records(reopened, [])
    reopened.close()


def test_close_during_worker_build_discards_output() raises:
    var path = String("/tmp/akasha-52-worker-cancel")
    var collection = _slow_collection(path)
    var manifest_bytes = read_file_bytes(path + "/manifest.bin")
    assert_true(collection.schedule_maintenance())
    _await_job_pin(collection)

    # Cancel is not a failure: close joins the job, which discards its files.
    collection.close()

    assert_true(read_file_bytes(path + "/manifest.bin") == manifest_bytes)
    assert_equal(len(_job_outputs(path)), 0)
    assert_equal(collection._pins[].active_count(), 0)
    var reopened = PersistentCollection.open_with_config(
        path, _cheap_config(_DIMENSION)
    )
    assert_equal(len(load_manifest(path, _DIMENSION).segments), 3)
    _assert_slow_records(reopened, [])
    reopened.close()


def test_exhausted_worker_budget_is_counted_not_a_failure() raises:
    var path = String("/tmp/akasha-52-worker-exhausted")
    var collection = _slow_collection(path)
    collection._maintenance._state[].compaction_delay_for_test = 0.3
    assert_true(collection.schedule_maintenance())
    var id = 90_000
    for attempt in range(COMPACTION_ATTEMPTS):
        _await_attempts(collection, attempt + 1)
        # Deliberately bypass public job admission to test defensive stale
        # publication handling. Normal public compactions are serialized.
        with BlockingScopedLock(collection._writer_lock[]):
            var counts = collection._maintenance.compaction_counts()
            assert_equal(counts.conflicts, attempt)
            collection._upsert_unlocked(id, _vector(id, _DIMENSION))
            _ = collection._checkpoint_unlocked()
        var injected = collection._begin_compaction()
        var output = collection._build_compaction(injected.value())
        assert_true(collection._finish_compaction(injected.value(), output))
        with BlockingScopedLock(collection._writer_lock[]):
            collection._upsert_unlocked(id + 1, _vector(id + 1, _DIMENSION))
            _ = collection._checkpoint_unlocked()
        id += 2

    assert_true(collection.wait_for_maintenance())
    var counts = collection.background_compaction_counts()
    assert_equal(counts.attempts, COMPACTION_ATTEMPTS)
    assert_equal(counts.conflicts, COMPACTION_ATTEMPTS)
    assert_equal(counts.exhausted, 1)
    assert_equal(collection._pins[].active_count(), 0)
    # Reclaim the retired winner files; only the latest published pair remains.
    collection.flush()
    var published = load_manifest(path, _DIMENSION)
    var outputs = _job_outputs(path)
    assert_equal(len(outputs), 2)
    for name in outputs:
        assert_true(
            name == published.segments[0].name
            or name == published.segments[0].sparse_name
        )

    # The collection stays usable and the worker takes the next request.
    collection.upsert(id, _vector(id, _DIMENSION))
    assert_true(collection.schedule_maintenance())
    assert_true(collection.wait_for_maintenance())
    counts = collection.background_compaction_counts()
    assert_equal(counts.attempts, COMPACTION_ATTEMPTS + 1)
    assert_equal(counts.exhausted, 1)
    assert_equal(len(load_manifest(path, _DIMENSION).segments), 1)
    var written = List[Int]()
    for extra in range(90_000, id + 1):
        written.append(extra)
    _assert_slow_records(collection, written)
    collection.close()


def test_eighth_sealed_run_schedules_worker_merge() raises:
    var path = String("/tmp/akasha-52-sealed-merge")
    var collection = _small_collection(path)
    with BlockingScopedLock(collection._writer_lock[]):
        for run in range(MAX_SEALED_RUNS):
            _ = collection._apply_batch_unlocked(
                _batch(run * HEAD_MAX_POINTS, HEAD_MAX_POINTS, 4)
            )
        # Nothing merges under the writer's lock.
        assert_equal(
            collection._read_generations[].sealed_count(), MAX_SEALED_RUNS
        )
        assert_equal(collection._read_generations[].stats.consolidations, 0)

    assert_true(collection.wait_for_maintenance())
    with BlockingScopedLock(collection._writer_lock[]):
        assert_equal(collection._read_generations[].sealed_count(), 0)
        assert_equal(collection._read_generations[].stats.consolidations, 1)
    var snapshot = collection.snapshot()
    assert_equal(len(snapshot.documents()), MAX_SEALED_RUNS * HEAD_MAX_POINTS)
    snapshot.close()
    collection.close()


def test_merge_publish_replaces_only_the_captured_prefix() raises:
    var table = MemTable(4)
    var pins = ArcPointer(GenerationPinRegistry())
    var config = CollectionConfig.defaults(4)
    var cache = ReadGenerationCache()
    var sequence = UInt64(0)
    for id in range(10):
        sequence += 1
        table.apply_upsert(id, sequence, _vector(id, 4))
    var original = cache.acquire(config, 0, sequence, table, pins)

    var id = 1000
    while not cache.merge_due():
        sequence += 1
        table.apply_upsert(id, sequence, _vector(id, 4))
        cache.record(table, [id], sequence)
        id += 1
    assert_equal(cache.sealed_count(), MAX_SEALED_RUNS)
    var merge = cache.capture_merge()
    merge.build()

    # While the merge built, the writer sealed one more run and began a head
    # holding a new state for a merged ID and a base ID.
    for _ in range(HEAD_MAX_POINTS):
        sequence += 1
        table.apply_upsert(id, sequence, _vector(id, 4))
        cache.record(table, [id], sequence)
        id += 1
    sequence += 1
    table.apply_delete(1000, sequence)
    cache.record(table, [1000], sequence)
    sequence += 1
    table.apply_upsert(3, sequence, _vector(-3, 4))
    cache.record(table, [3], sequence)
    var before = cache.acquire(config, 0, sequence, table, pins)
    var later = before[].layers[MAX_SEALED_RUNS + 1].run.copy()

    assert_true(cache.publish_merge(merge^))
    assert_equal(cache.sealed_count(), 1)
    assert_equal(cache.head_count(), 2)
    assert_equal(cache.stats.consolidations, 1)
    var merged = cache.acquire(config, 0, sequence, table, pins)
    assert_equal(merged[].layer_count(), 3)
    assert_true(merged[].layers[1].run is later)
    assert_equal(merged[].visible_count, table.live_count())
    assert_equal(merged[].find(1000)[0], -1)
    assert_equal(merged[].find(3)[0], 2)
    for check in [0, 1001, id - 1]:
        var location = merged[].find(check)
        assert_true(location[0] >= 0)
        assert_equal(
            merged[]
            .run(location[0])
            .memtable.entry_ref_at(location[1])
            .dense_address(),
            table.entry_ref_at(table.ordinal_for(check)).dense_address(),
        )
    # Old roots keep their chains.
    assert_equal(original[].visible_count, 10)
    assert_equal(before[].layer_count(), MAX_SEALED_RUNS + 3)
    _ = original^
    _ = before^
    _ = merged^
    cache.reset()
    assert_equal(pins[].active_count(), 0)


def test_merge_captured_before_reset_is_discarded() raises:
    var table = MemTable(4)
    var pins = ArcPointer(GenerationPinRegistry())
    var config = CollectionConfig.defaults(4)
    var cache = ReadGenerationCache()
    var sequence = UInt64(0)
    _ = cache.acquire(config, 0, sequence, table, pins)
    var id = 0
    while not cache.merge_due():
        sequence += 1
        table.apply_upsert(id, sequence, _vector(id, 4))
        cache.record(table, [id], sequence)
        id += 1
    var merge = cache.capture_merge()
    merge.build()
    cache.reset()
    _ = cache.acquire(config, 0, sequence, table, pins)

    assert_false(cache.publish_merge(merge^))
    assert_equal(cache.stats.consolidations, 0)
    assert_equal(cache.sealed_count(), 0)
    cache.reset()


def test_missing_worker_merges_sealed_runs_inline() raises:
    var path = String("/tmp/akasha-52-sealed-merge-inline")
    _reset(path)
    var collection = PersistentCollection.open_with_config(
        path,
        _cheap_config(4),
        maintenance_library_path="/missing/libakasha-worker.so",
    )
    assert_false(collection.background_maintenance_enabled())
    var base = collection.snapshot()
    base.close()
    for run in range(MAX_SEALED_RUNS):
        _ = collection.apply_batch(
            _batch(run * HEAD_MAX_POINTS, HEAD_MAX_POINTS, 4)
        )
    assert_equal(collection._read_generations[].sealed_count(), 0)
    assert_equal(collection._read_generations[].stats.consolidations, 1)
    var snapshot = collection.snapshot()
    assert_equal(len(snapshot.documents()), MAX_SEALED_RUNS * HEAD_MAX_POINTS)
    snapshot.close()
    collection.close()


def test_backpressure_waits_for_merge_without_losing_writes() raises:
    var path = String("/tmp/akasha-52-sealed-backpressure")
    var collection = _small_collection(path)
    with BlockingScopedLock(collection._writer_lock[]):
        collection._read_generations[].merge_delay_for_test = 0.2
    var runs = SEALED_RUN_LIMIT + 4
    var most = 0
    for run in range(runs):
        _ = collection.apply_batch(
            _batch(run * HEAD_MAX_POINTS, HEAD_MAX_POINTS, 4)
        )
        with BlockingScopedLock(collection._writer_lock[]):
            most = max(most, collection._read_generations[].sealed_count())
    assert_true(collection._backpressure_waits >= 1)
    assert_true(most <= SEALED_RUN_LIMIT)

    _ = collection.wait_for_maintenance()
    with BlockingScopedLock(collection._writer_lock[]):
        collection._read_generations[].merge_delay_for_test = 0.0
    var snapshot = collection.snapshot()
    var documents = snapshot.documents()
    assert_equal(len(documents), runs * HEAD_MAX_POINTS)
    for index in range(len(documents)):
        assert_equal(documents[index].id, index)
    snapshot.close()
    collection.close()

    var reopened = PersistentCollection.open_with_config(path, _cheap_config(4))
    assert_equal(reopened.last_sequence(), UInt64(runs * HEAD_MAX_POINTS))
    reopened.close()


def test_close_during_backpressure_wait_keeps_acked_writes() raises:
    var path = String("/tmp/akasha-52-sealed-backpressure-close")
    var collection = _small_collection(path)
    with BlockingScopedLock(collection._writer_lock[]):
        collection._read_generations[].merge_delay_for_test = 1.0
        for run in range(SEALED_RUN_LIMIT):
            _ = collection._apply_batch_unlocked(
                _batch(run * HEAD_MAX_POINTS, HEAD_MAX_POINTS, 4)
            )
    var acked = UInt64(SEALED_RUN_LIMIT * HEAD_MAX_POINTS)
    var closed_errors = Atomic[DType.int64](0)
    var other_errors = Atomic[DType.int64](0)

    def write_or_close(
        task: Int,
    ) {mut collection, mut closed_errors, mut other_errors}:
        if task == 0:
            try:
                collection.upsert(1_000_000, _vector(1_000_000, 4))
            except error:
                if "collection is closed" in String(error):
                    _ = closed_errors.fetch_add(1)
                else:
                    _ = other_errors.fetch_add(1)
            return
        sleep(0.1)
        try:
            collection.close()
        except:
            _ = other_errors.fetch_add(1)

    parallelize(write_or_close, 2, 2)

    assert_equal(closed_errors.load(), 1)
    assert_equal(other_errors.load(), 0)
    assert_equal(collection._backpressure_waits, 1)
    var reopened = PersistentCollection.open_with_config(path, _cheap_config(4))
    assert_equal(reopened.last_sequence(), acked)
    assert_false(Bool(reopened.get(1_000_000)))
    assert_equal(reopened.get(0).value().vector[0], 0.0)
    reopened.close()


def _drop_during_merge(path: String) raises:
    var collection = _small_collection(path)
    collection._read_generations[].merge_delay_for_test = 0.3
    for run in range(MAX_SEALED_RUNS):
        _ = collection.apply_batch(
            _batch(run * HEAD_MAX_POINTS, HEAD_MAX_POINTS, 4)
        )
    # Dropped unclosed while the worker sleeps inside the merge build.


def test_dropping_an_open_collection_joins_a_running_merge() raises:
    var path = String("/tmp/akasha-52-drop-during-merge")
    # A use after free only faults when the memory is reused; repeat it.
    for _ in range(4):
        _drop_during_merge(path)
        var reopened = PersistentCollection.open_with_config(
            path, _cheap_config(4)
        )
        assert_equal(
            reopened.last_sequence(), UInt64(MAX_SEALED_RUNS * HEAD_MAX_POINTS)
        )
        var snapshot = reopened.snapshot()
        assert_equal(
            len(snapshot.documents()), MAX_SEALED_RUNS * HEAD_MAX_POINTS
        )
        snapshot.close()
        reopened.close()


def test_merge_failure_reports_without_losing_acked_writes() raises:
    var path = String("/tmp/akasha-52-sealed-merge-failure")
    var collection = _small_collection(path)
    with BlockingScopedLock(collection._writer_lock[]):
        collection._read_generations[].merge_failure_for_test = True
    for run in range(MAX_SEALED_RUNS):
        _ = collection.apply_batch(
            _batch(run * HEAD_MAX_POINTS, HEAD_MAX_POINTS, 4)
        )
    with assert_raises(contains="background maintenance failed"):
        _ = collection.wait_for_maintenance()
    with assert_raises(contains="background maintenance failed"):
        collection.upsert(1_000_000, _vector(1_000_000, 4))
    with assert_raises(contains="background maintenance failed"):
        collection.close()

    var reopened = PersistentCollection.open_with_config(path, _cheap_config(4))
    var acked = MAX_SEALED_RUNS * HEAD_MAX_POINTS
    assert_equal(reopened.last_sequence(), UInt64(acked))
    var snapshot = reopened.snapshot()
    assert_equal(len(snapshot.documents()), acked)
    snapshot.close()
    reopened.close()


def _level_zero_count(collection: PersistentCollection) raises -> Int:
    """Count under the writer lock, which a publish holds to reclaim inputs."""
    with BlockingScopedLock(collection._writer_lock[]):
        return CompactionPolicy(LEVEL_ZERO_SEGMENT_LIMIT).level_zero_count(
            load_manifest(collection._path, 4)
        )


def _flush_to_level_zero_limit(mut collection: PersistentCollection) raises:
    """Flush one write at a time until the deltas reach the level-zero limit.

    The first flush writes the base. The job requested at four deltas still
    sleeps before its build.
    """
    for id in range(LEVEL_ZERO_SEGMENT_LIMIT + 1):
        collection.upsert(id, _vector(id, 4))
        collection.flush()
    assert_equal(_level_zero_count(collection), LEVEL_ZERO_SEGMENT_LIMIT)


def test_writes_flushes_and_worker_keep_segments_bounded() raises:
    var path = String("/tmp/akasha-52-worker-stress")
    _reset(path)
    var collection = PersistentCollection.open_with_config(
        path, _cheap_config(4)
    )
    var most = 0
    var written = 0
    for _ in range(40):
        for _ in range(25):
            collection.upsert(written, _vector(written, 4))
            written += 1
        collection.flush()
        most = max(most, _level_zero_count(collection))
    assert_true(collection.wait_for_maintenance())

    var counts = collection.background_compaction_counts()
    assert_true(counts.attempts - counts.conflicts >= 1)
    assert_equal(counts.exhausted, 0)
    assert_true(most <= LEVEL_ZERO_SEGMENT_LIMIT)
    var expected = collection.last_sequence()
    collection.close()

    var reopened = PersistentCollection.open_with_config(path, _cheap_config(4))
    assert_equal(reopened.last_sequence(), expected)
    for id in range(written):
        assert_equal(reopened.get(id).value().vector[0], Float32(id))
    reopened.close()


def test_flush_waits_for_compaction_at_the_level_zero_limit() raises:
    var path = String("/tmp/akasha-52-flush-stall")
    var collection = _small_collection(path)
    collection._maintenance._state[].compaction_delay_for_test = 0.5
    _flush_to_level_zero_limit(collection)
    var written = LEVEL_ZERO_SEGMENT_LIMIT + 5
    var most = 0
    for id in range(LEVEL_ZERO_SEGMENT_LIMIT + 1, written):
        collection.upsert(id, _vector(id, 4))
        collection.flush()
        most = max(most, _level_zero_count(collection))
    assert_true(collection._backpressure_waits >= 1)
    assert_true(most <= LEVEL_ZERO_SEGMENT_LIMIT)

    assert_true(collection.wait_for_maintenance())
    collection.close()
    var reopened = PersistentCollection.open_with_config(path, _cheap_config(4))
    assert_equal(reopened.last_sequence(), UInt64(written))
    for id in range(written):
        assert_equal(reopened.get(id).value().vector[0], Float32(id))
    reopened.close()


def test_close_during_flush_wait_keeps_acked_writes() raises:
    var path = String("/tmp/akasha-52-flush-stall-close")
    var collection = _small_collection(path)
    collection._maintenance._state[].compaction_delay_for_test = 1.0
    _flush_to_level_zero_limit(collection)
    var acked = LEVEL_ZERO_SEGMENT_LIMIT + 1
    collection.upsert(acked, _vector(acked, 4))
    var closed_errors = Atomic[DType.int64](0)
    var other_errors = Atomic[DType.int64](0)

    def flush_or_close(
        task: Int,
    ) {mut collection, mut closed_errors, mut other_errors}:
        if task == 0:
            try:
                collection.flush()
            except error:
                if "collection is closed" in String(error):
                    _ = closed_errors.fetch_add(1)
                else:
                    _ = other_errors.fetch_add(1)
            return
        sleep(0.1)
        try:
            collection.close()
        except:
            _ = other_errors.fetch_add(1)

    parallelize(flush_or_close, 2, 2)

    assert_equal(closed_errors.load(), 1)
    assert_equal(other_errors.load(), 0)
    assert_equal(collection._backpressure_waits, 1)
    var reopened = PersistentCollection.open_with_config(path, _cheap_config(4))
    assert_equal(reopened.last_sequence(), UInt64(acked + 1))
    assert_equal(reopened.get(acked).value().vector[0], Float32(acked))
    reopened.close()


def test_compaction_failure_ends_the_flush_wait() raises:
    var path = String("/tmp/akasha-52-flush-stall-failure")
    var collection = _small_collection(path)
    collection._maintenance._state[].compaction_delay_for_test = 0.5
    _flush_to_level_zero_limit(collection)
    # The sleeping job captured the first delta, so its build fails.
    var victim = path + "/" + load_manifest(path, 4).segments[1].name
    var original = read_file_bytes(victim)
    var corrupted = original.copy()
    corrupted[len(corrupted) // 2] ^= 0xFF
    write_file_sync(victim, corrupted)
    var acked = LEVEL_ZERO_SEGMENT_LIMIT + 1
    collection.upsert(acked, _vector(acked, 4))

    with assert_raises(contains="background maintenance failed"):
        collection.flush()
    assert_equal(collection._backpressure_waits, 1)
    with assert_raises(contains="background maintenance failed"):
        collection.close()

    write_file_sync(victim, original)
    var reopened = PersistentCollection.open_with_config(path, _cheap_config(4))
    assert_equal(reopened.last_sequence(), UInt64(acked + 1))
    for id in range(acked + 1):
        assert_equal(reopened.get(id).value().vector[0], Float32(id))
    reopened.close()


def test_flushes_faster_than_a_build_do_not_exhaust_compaction() raises:
    var path = String("/tmp/akasha-52-worker-flush-race")
    var collection = _slow_collection(path)
    var exhausted = Atomic[DType.int64](0)
    var failures = Atomic[DType.int64](0)
    var foreground_published = Atomic[DType.int64](0)

    def flush_or_compact(
        task: Int,
    ) {mut collection, mut exhausted, mut failures, mut foreground_published}:
        if task == 0:
            for _ in range(3):
                try:
                    var before = collection.compaction_conflicts()
                    var attempts = collection.compaction_attempts()
                    collection.compact()
                    var taken = collection.compaction_attempts() - attempts
                    var lost = collection.compaction_conflicts() - before
                    if taken > lost:
                        _ = foreground_published.fetch_add(1)
                except error:
                    if "retry budget" in String(error):
                        _ = exhausted.fetch_add(1)
                    else:
                        _ = failures.fetch_add(1)
                sleep(0.05)
            return
        try:
            for offset in range(40):
                var id = 90_000 + offset
                collection.upsert(id, _vector(id, _DIMENSION))
                collection.flush()
                sleep(0.01)
        except:
            _ = failures.fetch_add(1)

    parallelize(flush_or_compact, 2, 2)
    assert_true(collection.wait_for_maintenance())

    assert_equal(failures.load(), 0)
    assert_equal(exhausted.load(), 0)
    assert_true(foreground_published.load() >= 1)
    var counts = collection.background_compaction_counts()
    assert_equal(counts.exhausted, 0)
    assert_true(counts.attempts - counts.conflicts >= 1)
    var expected = collection.last_sequence()
    collection.close()

    var reopened = PersistentCollection.open_with_config(
        path, _cheap_config(_DIMENSION)
    )
    assert_equal(reopened.last_sequence(), expected)
    var written = List[Int]()
    for offset in range(40):
        written.append(90_000 + offset)
    _assert_slow_records(reopened, written)
    reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
