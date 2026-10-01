"""Measure HNSW capture/build/publish separately, including bounded catch-up."""

from akasha import (
    BatchMutation,
    CollectionConfig,
    MetricKind,
    PersistentCollection,
)
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.memtable import MemTable
from std.time import perf_counter_ns
from std.utils import BlockingScopedLock

comptime DIMENSION = 128
comptime ROUNDS = 3


def _vector(id: Int) -> List[Float32]:
    var result = List[Float32](capacity=DIMENSION)
    var state = UInt64(id + 1) * UInt64(0x9E3779B97F4A7C15)
    for _ in range(DIMENSION):
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        result.append(Float32(state & 65535) / 65535.0)
    return result^


def _run(points: Int, changed: Int, round: Int) raises:
    var path = String("/tmp/akasha-hnsw-rebuild-bench")
    ensure_directory(path)
    for name in ["manifest.bin", "wal.bin", "sparse.wal"]:
        remove_file_if_exists(path + "/" + name)
    var config = CollectionConfig.defaults(DIMENSION)
    config.ann_metric = MetricKind.l2()
    config.m = 8
    config.m0 = 16
    config.ef_construction = 64
    config.max_level = 8
    var collection = PersistentCollection.open_with_config(
        path, config, maintenance_library_path="/missing/worker"
    )
    var mutations = List[BatchMutation](capacity=points)
    for id in range(points):
        mutations.append(BatchMutation.upsert(id, _vector(id)))
    _ = collection.apply_batch(mutations)
    # Steady-state root acquisition; cold publisher bootstrap is excluded.
    var snapshot = collection.snapshot()
    snapshot.close()
    var started = perf_counter_ns()
    var job = collection._begin_hnsw_rebuild()
    var capture = perf_counter_ns() - started
    started = perf_counter_ns()
    var candidate = job[].build()
    var build = perf_counter_ns() - started
    var tail = List[BatchMutation](capacity=changed)
    for id in range(changed):
        tail.append(BatchMutation.upsert(id, _vector(points + id)))
    if changed > 0:
        _ = collection.apply_batch(tail)
    started = perf_counter_ns()
    var detached: MemTable
    with BlockingScopedLock(collection._writer_lock[]):
        detached = job[].take_tail()
    var detach = perf_counter_ns() - started
    started = perf_counter_ns()
    job[].catch_up(detached, candidate)
    var catchup = perf_counter_ns() - started
    started = perf_counter_ns()
    if not collection._finish_hnsw_rebuild(job, candidate^):
        raise Error("benchmark rebuild failed to publish")
    var publish = perf_counter_ns() - started
    if collection._hnsw.current_point_count() != points:
        raise Error("benchmark rebuild lost points")
    collection._hnsw.validate_structure()
    var query = _vector(points if changed > 0 else 0)
    var exact = collection.search_l2(query, 1)
    var ann = collection.search_l2_approx(query, 1, 512)
    if exact[0].id != ann[0].id or exact[0].score != ann[0].score:
        raise Error("benchmark rebuild nearest-point oracle mismatch")
    print(
        String(points)
        + ","
        + String(DIMENSION)
        + ","
        + String(changed)
        + ","
        + String(round)
        + ","
        + String(capture)
        + ","
        + String(build)
        + ","
        + String(detach)
        + ","
        + String(catchup)
        + ","
        + String(publish)
    )
    collection.close()


def main() raises:
    print(
        "points,dimension,tail_points,round,capture_ns,build_ns,detach_ns,catchup_ns,publish_ns"
    )
    for points in [1024, 4096]:
        for changed in [0, 16, 1024]:
            for round in range(ROUNDS):
                _run(points, changed, round)
