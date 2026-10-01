"""Writer stall during compaction and sealed-run merges, and conflicts (#51, #52).

Every case paces a writer at one upsert per period with no catch-up bursts, so
each revision writes the same volume, and times every call.

Stall case: another task sleeps a fixed gap, flushes, then compacts, each
round. Upserts are classified by the call they overlapped; `*_only` drops the
upserts that also overlapped the flush before the job.

Worker stall case: the same rounds hand the compaction to the background
worker (`schedule_maintenance`) and wait for it.

Sealed case: after a read root gives the publisher its base, the writer alone
rolls the head into sealed runs until the eighth run merges, several times.
Upserts are classified by whether a merge or a rollover landed during them.

Conflict case: compact() rounds race a paced writer that also flushes once per
period; reports the attempt and conflict counters and the most segments any
flush left in the manifest.

Lines marked `# #52 only` use API added by #52; the baseline build drops them.
Prints one `name=value` line per metric; latencies in microseconds.
"""

from akasha import PersistentCollection
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.manifest import load_manifest
from akasha.storage.read_generation import HEAD_MAX_POINTS, MAX_SEALED_RUNS
from max.algorithm import parallelize
from std.atomic import Atomic
from std.os import listdir
from std.time import perf_counter_ns, sleep
from std.utils import BlockingScopedLock

comptime POINTS = 20000
comptime DIMENSION = 128
comptime ROUNDS = 20
comptime WRITE_PERIOD_NS = 1_000_000
comptime ROUND_GAP_SECONDS = 0.2
comptime SEALED_MERGES = 3


def _vector(id: Int) -> List[Float32]:
    var values = List[Float32](capacity=DIMENSION)
    for index in range(DIMENSION):
        values.append(Float32((id * 31 + index * 7) % 97) / 97.0)
    return values^


def _now() -> Int:
    return Int(perf_counter_ns())


def _seed(path: String) raises -> PersistentCollection:
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)
    var collection = PersistentCollection.open(path, DIMENSION)
    for id in range(POINTS):
        collection.upsert(id, _vector(id))
    collection.flush()
    return collection^


def _pace(mut next: Int):
    """Wait for the next write slot; a late writer starts now, no burst."""
    var now = _now()
    if now < next:
        sleep(Float64(next - now) / 1e9)
    else:
        next = now
    next += WRITE_PERIOD_NS


def _percentile(sorted: List[Int], fraction: Float64) -> Float64:
    if len(sorted) == 0:
        return 0.0
    var index = Int(fraction * Float64(len(sorted) - 1) + 0.5)
    return Float64(sorted[index]) / 1000.0


def _report(name: String, var samples: List[Int]):
    sort(Span(samples))
    print(name + "_calls=" + String(len(samples)))
    print(name + "_p50_us=" + String(_percentile(samples, 0.50)))
    print(name + "_p95_us=" + String(_percentile(samples, 0.95)))
    print(name + "_p99_us=" + String(_percentile(samples, 0.99)))
    print(name + "_max_us=" + String(_percentile(samples, 1.0)))


def _overlaps(
    windows: List[Int], mut cursor: Int, start: Int, end: Int
) -> Bool:
    """Whether [start, end] overlaps a window; windows are sorted pairs."""
    while cursor + 1 < len(windows) and windows[cursor + 1] < start:
        cursor += 2
    return cursor + 1 < len(windows) and windows[cursor] <= end


def _timed_upsert(
    mut collection: PersistentCollection,
    id: Int,
    mut starts: List[Int],
    mut ends: List[Int],
) raises:
    """Upsert one point and record the call's start and end.

    The caller polls its stop flag itself: a helper spinning on an atomic
    passed as `mut` never saw the other task's store in a Mojo 1.0 probe.
    """
    var vector = _vector(id)
    var start = _now()
    collection.upsert(id % POINTS, vector^)
    starts.append(start)
    ends.append(_now())


def _report_stalls(
    prefix: String,
    job: String,
    jobs: List[Int],
    flushes: List[Int],
    starts: List[Int],
    ends: List[Int],
):
    """Report job and flush durations and upserts by the call they overlapped.

    A job starts when its flush returns, so an upsert queued behind the flush
    also overlaps the job; `job_only` excludes those.
    """
    var during_job = List[Int]()
    var job_only = List[Int]()
    var during_flush = List[Int]()
    var quiet = List[Int]()
    var job_cursor = 0
    var flush_cursor = 0
    for index in range(len(starts)):
        var latency = ends[index] - starts[index]
        var flushed = _overlaps(
            flushes, flush_cursor, starts[index], ends[index]
        )
        if _overlaps(jobs, job_cursor, starts[index], ends[index]):
            during_job.append(latency)
            if not flushed:
                job_only.append(latency)
        elif flushed:
            during_flush.append(latency)
        else:
            quiet.append(latency)
    var durations = List[Int]()
    for index in range(0, len(jobs), 2):
        durations.append(jobs[index + 1] - jobs[index])
    var flush_durations = List[Int]()
    for index in range(0, len(flushes), 2):
        flush_durations.append(flushes[index + 1] - flushes[index])
    _report(prefix + "_" + job + "_call", durations^)
    _report(prefix + "_flush_call", flush_durations^)
    _report(prefix + "_upsert_during_" + job, during_job^)
    _report(prefix + "_upsert_" + job + "_only", job_only^)
    _report(prefix + "_upsert_during_flush", during_flush^)
    _report(prefix + "_upsert_quiet", quiet^)


def bench_stall() raises:
    var collection = _seed("/tmp/akasha-51-bench-stall")
    var done = Atomic[DType.int64](0)
    var failures = Atomic[DType.int64](0)
    var flushes = List[Int]()
    var compactions = List[Int]()
    var starts = List[Int]()
    var ends = List[Int]()

    def run(
        task: Int,
    ) {
        mut collection,
        mut done,
        mut failures,
        mut flushes,
        mut compactions,
        mut starts,
        mut ends,
    }:
        try:
            if task == 0:
                for _ in range(ROUNDS):
                    sleep(ROUND_GAP_SECONDS)
                    flushes.append(_now())
                    collection.flush()
                    var start = _now()
                    flushes.append(start)
                    collection.compact()
                    compactions.append(start)
                    compactions.append(_now())
                _ = done.fetch_add(1)
                return
            var id = 0
            var next = _now()
            while done.load() == 0:
                _pace(next)
                _timed_upsert(collection, id, starts, ends)
                id += 1
        except error:
            print("task " + String(task) + " error: " + String(error))
            _ = failures.fetch_add(1)
            _ = done.fetch_add(1)

    parallelize(run, 2, 2)
    if failures.load() != 0:
        raise Error("stall bench task failed")
    _report_stalls("stall", "compact", compactions, flushes, starts, ends)
    collection.close()


def bench_worker_stall() raises:
    var collection = _seed("/tmp/akasha-52-bench-worker-stall")
    if not collection.background_maintenance_enabled():
        raise Error("worker stall bench needs the maintenance worker library")
    var done = Atomic[DType.int64](0)
    var failures = Atomic[DType.int64](0)
    var flushes = List[Int]()
    var jobs = List[Int]()
    var starts = List[Int]()
    var ends = List[Int]()

    def run(
        task: Int,
    ) {
        mut collection,
        mut done,
        mut failures,
        mut flushes,
        mut jobs,
        mut starts,
        mut ends,
    }:
        try:
            if task == 0:
                for _ in range(ROUNDS):
                    sleep(ROUND_GAP_SECONDS)
                    flushes.append(_now())
                    collection.flush()
                    var start = _now()
                    flushes.append(start)
                    _ = collection.schedule_maintenance()
                    # Raises on a worker failure; the result only says it ran.
                    _ = collection.wait_for_maintenance()
                    jobs.append(start)
                    jobs.append(_now())
                _ = done.fetch_add(1)
                return
            var id = 0
            var next = _now()
            while done.load() == 0:
                _pace(next)
                _timed_upsert(collection, id, starts, ends)
                id += 1
        except error:
            print("task " + String(task) + " error: " + String(error))
            _ = failures.fetch_add(1)
            _ = done.fetch_add(1)

    parallelize(run, 2, 2)
    if failures.load() != 0:
        raise Error("worker stall bench task failed")
    if len(load_manifest(collection._path, DIMENSION).segments) != 1:
        raise Error("worker stall bench left segments uncompacted")
    _report_stalls("worker", "job", jobs, flushes, starts, ends)
    collection.close()


def bench_sealed_stall() raises:
    var collection = _seed("/tmp/akasha-52-bench-sealed")
    # A read root gives the publisher its base; writes then roll into runs.
    var base = collection.snapshot()
    base.close()
    var writes = SEALED_MERGES * MAX_SEALED_RUNS * HEAD_MAX_POINTS
    writes += HEAD_MAX_POINTS // 2
    var every = List[Int]()
    var at_merge = List[Int]()
    var at_rollover = List[Int]()
    var other = List[Int]()
    var merges = 0
    var rollovers = 0
    var next = _now()
    for id in range(writes):
        _pace(next)
        var vector = _vector(id)
        var start = _now()
        collection.upsert(id % POINTS, vector^)
        var latency = _now() - start
        # Read outside the timed call; the worker updates stats under the lock.
        var seen_merges: Int
        var seen_rollovers: Int
        with BlockingScopedLock(collection._writer_lock[]):
            ref stats = collection._read_generations[].stats
            seen_merges = stats.consolidations
            seen_rollovers = stats.rollovers
        if seen_merges != merges:
            at_merge.append(latency)
        elif seen_rollovers != rollovers:
            at_rollover.append(latency)
        else:
            other.append(latency)
        every.append(latency)
        merges = seen_merges
        rollovers = seen_rollovers
    _ = collection.wait_for_maintenance()
    with BlockingScopedLock(collection._writer_lock[]):
        merges = collection._read_generations[].stats.consolidations
    if merges != SEALED_MERGES:
        raise Error(
            "sealed bench expected " + String(SEALED_MERGES) + " merges"
        )
    _report("sealed_upsert", every^)
    _report("sealed_upsert_at_merge", at_merge^)
    _report("sealed_upsert_at_rollover", at_rollover^)
    _report("sealed_upsert_other", other^)
    print("sealed_merges=" + String(merges))
    print("sealed_rollovers=" + String(rollovers))
    var waits = collection._backpressure_waits  # #52 only
    print("sealed_backpressure_waits=" + String(waits))  # #52 only
    collection.close()


def bench_conflict(flush_period_ms: Int) raises:
    var path = String("/tmp/akasha-51-bench-conflict")
    var collection = _seed(path)
    var done = Atomic[DType.int64](0)
    var failures = Atomic[DType.int64](0)
    var exhausted = Atomic[DType.int64](0)
    var flushes = Atomic[DType.int64](0)
    var max_segments = 0
    var period_ns = flush_period_ms * 1_000_000

    def run(
        task: Int,
    ) {
        mut collection,
        mut done,
        mut failures,
        mut exhausted,
        mut flushes,
        mut max_segments,
        path,
        period_ns,
    }:
        if task == 0:
            for _ in range(ROUNDS):
                try:
                    sleep(ROUND_GAP_SECONDS)
                    collection.compact()
                except error:
                    if "retry budget" in String(error):
                        _ = exhausted.fetch_add(1)
                    else:
                        print("compact error: " + String(error))
                        _ = failures.fetch_add(1)
            _ = done.fetch_add(1)
            return
        try:
            var id = 0
            var next = _now()
            var deadline = next + period_ns
            while done.load() == 0:
                _pace(next)
                collection.upsert(id % POINTS, _vector(id))
                id += 1
                if _now() >= deadline:
                    collection.flush()
                    _ = flushes.fetch_add(1)
                    # A publish reclaims its inputs under the writer lock, so
                    # an unlocked read can name a segment already deleted.
                    with BlockingScopedLock(collection._writer_lock[]):
                        var manifest = load_manifest(path, DIMENSION)
                        max_segments = max(max_segments, len(manifest.segments))
                    deadline = _now() + period_ns
        except error:
            print("writer error: " + String(error))
            _ = failures.fetch_add(1)

    parallelize(run, 2, 2)
    if failures.load() != 0:
        raise Error("conflict bench task failed")
    _ = collection.wait_for_maintenance()
    var attempts = collection.compaction_attempts()
    var conflicts = collection.compaction_conflicts()
    var name = "conflict_flush_" + String(flush_period_ms) + "ms"
    print(name + "_flushes=" + String(flushes.load()))
    print(name + "_attempts=" + String(attempts))
    print(name + "_conflicts=" + String(conflicts))
    print(name + "_rate=" + String(Float64(conflicts) / Float64(attempts)))
    print(name + "_exhausted_calls=" + String(exhausted.load()))
    print(name + "_max_segments=" + String(max_segments))
    var worker = collection.background_compaction_counts()  # #52 only
    print(name + "_worker_attempts=" + String(worker.attempts))  # #52 only
    print(name + "_worker_conflicts=" + String(worker.conflicts))  # #52 only
    print(name + "_worker_exhausted=" + String(worker.exhausted))  # #52 only
    collection.close()


def main() raises:
    bench_stall()
    bench_worker_stall()
    bench_sealed_stall()
    for period in [50, 200, 1000]:
        bench_conflict(period)
