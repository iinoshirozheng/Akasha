"""Measure persistent generation-file capture and last-release metadata I/O.

Run without other workloads for latency measurements. This isolates file leases;
it does not measure read-root construction or database query time.
"""

from akasha import PersistentCollection
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.manifest import load_manifest
from std.os import listdir
from std.time import perf_counter_ns


def main() raises:
    var path = String("/tmp/akasha-file-lease-bench")
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)
    var collection = PersistentCollection.open(
        path, 1, maintenance_library_path="/akasha-bench-no-worker.so"
    )
    for id in range(32):
        collection.upsert(id, [Float32(id + 1)])
    collection.flush()
    var pins = GenerationPinRegistry(path, 1)
    for sample in range(31):
        var generation = load_manifest(path, 1).generation
        var start = perf_counter_ns()
        pins.pin(generation)
        var capture_ns = perf_counter_ns() - start
        var files = len(pins._pins[0].lease.value().files)
        start = perf_counter_ns()
        for _ in range(1024):
            pins.pin(generation)
            pins.unpin(generation)
        var shared_ns = perf_counter_ns() - start
        start = perf_counter_ns()
        pins.unpin(generation)
        var referenced_release_ns = perf_counter_ns() - start

        pins.pin(generation)
        collection.upsert(0, [Float32(sample + 100)])
        collection.flush()
        collection.compact()
        start = perf_counter_ns()
        pins.unpin(generation)
        var retired_release_ns = perf_counter_ns() - start
        if pins.active_count() != 0 or pins.cleanup_error().byte_length() > 0:
            raise Error("file lease benchmark cleanup failed")
        print(
            "sample="
            + String(sample)
            + " referenced_files="
            + String(files)
            + " capture_ns="
            + String(capture_ns)
            + " shared_pin_unpin_ns="
            + String(Float64(shared_ns) / 1024.0)
            + " referenced_release_ns="
            + String(referenced_release_ns)
            + " retired_release_ns="
            + String(retired_release_ns)
        )
    collection.close()
