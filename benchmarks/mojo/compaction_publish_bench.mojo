"""Writer stall during foreground compaction and its conflict rate (#51).

Stall case: a paced writer upserts at a fixed rate and times every call while
another task sleeps a fixed gap, flushes, then compacts, each round. Upserts
are classified by the call they overlapped. Pacing and the gap give both
revisions the same write volume and keep the spin lock from starving either
task. Uses only public API, so it runs on the pre-#51 revision too.

Conflict case: compact() rounds race a paced writer that also flushes once per
period; reports the #51 attempt and conflict counters.

Prints one `name=value` line per metric; latencies in microseconds.
"""

from akasha import PersistentCollection
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from max.algorithm import parallelize
from std.atomic import Atomic
from std.os import listdir
from std.time import perf_counter_ns, sleep

comptime POINTS = 20000
comptime DIMENSION = 128
comptime ROUNDS = 20
comptime WRITE_PERIOD_NS = 1_000_000
comptime ROUND_GAP_SECONDS = 0.2


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
                var vector = _vector(id)
                var start = _now()
                collection.upsert(id % POINTS, vector^)
                starts.append(start)
                ends.append(_now())
                id += 1
        except:
            _ = failures.fetch_add(1)
            _ = done.fetch_add(1)

    parallelize(run, 2, 2)
    if failures.load() != 0:
        raise Error("stall bench task failed")

    var during_compact = List[Int]()
    var during_flush = List[Int]()
    var quiet = List[Int]()
    var compact_cursor = 0
    var flush_cursor = 0
    for index in range(len(starts)):
        var latency = ends[index] - starts[index]
        if _overlaps(compactions, compact_cursor, starts[index], ends[index]):
            during_compact.append(latency)
        elif _overlaps(flushes, flush_cursor, starts[index], ends[index]):
            during_flush.append(latency)
        else:
            quiet.append(latency)
    var compact_ms = List[Int]()
    for index in range(0, len(compactions), 2):
        compact_ms.append(compactions[index + 1] - compactions[index])
    _report("stall_compact_call", compact_ms^)
    _report("stall_upsert_during_compact", during_compact^)
    _report("stall_upsert_during_flush", during_flush^)
    _report("stall_upsert_quiet", quiet^)
    collection.close()


def bench_conflict(flush_period_ms: Int) raises:
    var collection = _seed("/tmp/akasha-51-bench-conflict")
    var done = Atomic[DType.int64](0)
    var failures = Atomic[DType.int64](0)
    var exhausted = Atomic[DType.int64](0)
    var flushes = Atomic[DType.int64](0)
    var period_ns = flush_period_ms * 1_000_000

    def run(
        task: Int,
    ) {
        mut collection,
        mut done,
        mut failures,
        mut exhausted,
        mut flushes,
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
                    deadline = _now() + period_ns
        except:
            _ = failures.fetch_add(1)

    parallelize(run, 2, 2)
    if failures.load() != 0:
        raise Error("conflict bench task failed")
    var attempts = collection.compaction_attempts()
    var conflicts = collection.compaction_conflicts()
    var name = "conflict_flush_" + String(flush_period_ms) + "ms"
    print(name + "_flushes=" + String(flushes.load()))
    print(name + "_attempts=" + String(attempts))
    print(name + "_conflicts=" + String(conflicts))
    print(name + "_rate=" + String(Float64(conflicts) / Float64(attempts)))
    print(name + "_exhausted_calls=" + String(exhausted.load()))
    collection.close()


def main() raises:
    bench_stall()
    for period in [50, 200, 1000]:
        bench_conflict(period)
