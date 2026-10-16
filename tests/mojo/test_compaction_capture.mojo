from akasha import PersistentCollection
from akasha.storage.committed_compaction import (
    begin_compaction, _lease_compaction_inputs, CompactionInputs,
)
from akasha.storage.filesystem import (
    ensure_directory, path_exists, read_file_bytes,
    remove_file_if_exists, write_file_sync,
)
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.manifest import load_manifest
from max.algorithm import parallelize
from std.atomic import Atomic
from std.memory import ArcPointer
from std.os import listdir
from std.testing import assert_equal, assert_false, assert_raises, assert_true, TestSuite
from std.time import perf_counter_ns, sleep
from std.utils import BlockingScopedLock


def _collection(suffix: String) raises -> PersistentCollection:
    var path = "/tmp/akasha-unlocked-capture-" + suffix
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    collection.upsert(2, [2.0])
    collection.flush()
    assert_equal(len(load_manifest(path, 1).segments), 2)
    return collection^


def test_capture_finishes_without_writer_and_rebases_over_an_append() raises:
    var collection = _collection("race")
    var ready = Atomic[DType.int64](0)
    var done = Atomic[DType.int64](0)
    var failures = Atomic[DType.int64](0)
    var inputs = Optional[CompactionInputs]()

    def race(task: Int) {mut collection, mut ready, mut done, mut failures, mut inputs}:
        try:
            if task == 0:
                with BlockingScopedLock(collection._writer_lock[]):
                    ready.store(1)
                    var start = perf_counter_ns()
                    while done.load() == 0:
                        if perf_counter_ns() - start > 5_000_000_000:
                            raise Error("capture waited for writer")
                        sleep(0.0001)
                    collection._upsert_unlocked(3, [3.0])
                    _ = collection._checkpoint_unlocked()
            else:
                while ready.load() == 0:
                    sleep(0.0001)
                var capture = begin_compaction(collection._path, 1, collection._pins)
                assert_false(capture.stale)
                assert_true(Bool(capture.inputs))
                inputs = Optional(capture.inputs.take())
                done.store(1)
        except error:
            print(String(error))
            _ = failures.fetch_add(1)
            done.store(1)

    parallelize(race, 2, 2)
    assert_equal(failures.load(), 0)
    var output = collection._build_compaction(inputs.value())
    assert_true(collection._finish_compaction(inputs.value(), output))
    assert_equal(collection._pins[].active_count(), 0)
    assert_equal(collection.get(3).value().vector[0], Float32(3))
    var path = collection._path.copy()
    collection.close()
    var reopened = PersistentCollection.open(path, 1)
    for id in range(1, 4):
        assert_equal(reopened.get(id).value().vector[0], Float32(id))
    reopened.close()


def test_append_between_manifest_read_and_lease_does_not_retry() raises:
    var collection = _collection("append-before-pin")
    var manifest = load_manifest(collection._path, 1)
    collection.upsert(3, [3.0])
    collection.flush()
    var capture = _lease_compaction_inputs(collection._path, 1, manifest^, collection._pins)
    assert_false(capture.stale)
    assert_true(Bool(capture.inputs))
    var output = collection._build_compaction(capture.inputs.value())
    assert_true(collection._finish_compaction(capture.inputs.value(), output))
    assert_equal(collection._pins[].active_count(), 0)
    assert_equal(collection.get(3).value().vector[0], Float32(3))
    collection.close()


def test_missing_input_is_an_error_at_the_current_generation() raises:
    var collection = _collection("missing")
    var manifest = load_manifest(collection._path, 1)
    var source = collection._path + "/" + manifest.segments[1].name
    var bytes = read_file_bytes(source)
    remove_file_if_exists(source)
    with assert_raises():
        _ = begin_compaction(
            collection._path, 1, collection._pins,
        )
    assert_equal(collection._pins[].active_count(), 0)
    write_file_sync(source, bytes)
    collection.compact()
    collection.close()


def test_noop_capture_still_rejects_missing_authority() raises:
    var collection = _collection("noop-missing")
    collection.compact()
    var manifest = load_manifest(collection._path, 1)
    assert_equal(len(manifest.segments), 1)
    var source = collection._path + "/" + manifest.segments[0].name
    var bytes = read_file_bytes(source)
    remove_file_if_exists(source)
    with assert_raises():
        _ = begin_compaction(collection._path, 1, collection._pins)
    assert_equal(collection._pins[].active_count(), 0)
    write_file_sync(source, bytes)
    collection.close()


def test_retired_inputs_retry_after_a_failed_lease() raises:
    var collection = _collection("failed-stale")
    var manifest = load_manifest(collection._path, 1)
    collection.compact()
    assert_false(path_exists(collection._path + "/" + manifest.segments[0].name))
    var capture = _lease_compaction_inputs(collection._path, 1, manifest^, collection._pins)
    assert_true(capture.stale)
    assert_false(Bool(capture.inputs))
    assert_equal(collection._pins[].active_count(), 0)
    collection.close()


def test_replaced_inputs_retry_even_when_lease_succeeds() raises:
    var collection = _collection("successful-stale")
    var manifest = load_manifest(collection._path, 1)
    var generation = manifest.generation
    collection._pins[].pin(generation)
    collection.compact()
    assert_true(path_exists(collection._path + "/" + manifest.segments[0].name))
    var capture = _lease_compaction_inputs(collection._path, 1, manifest^, collection._pins)
    assert_true(capture.stale)
    assert_false(Bool(capture.inputs))
    assert_equal(collection._pins[].active_count(), 1)
    collection._pins[].unpin(generation)
    assert_equal(collection._pins[].active_count(), 0)
    collection.close()


def test_catalog_error_releases_the_successful_lease() raises:
    var collection = _collection("catalog")
    var catalog = collection._path + "/collection.bin"
    var bytes = read_file_bytes(catalog)
    var damaged = bytes.copy()
    damaged[0] ^= 1
    write_file_sync(catalog, damaged)
    with assert_raises():
        _ = begin_compaction(
            collection._path, 1, collection._pins,
        )
    assert_equal(collection._pins[].active_count(), 0)
    write_file_sync(catalog, bytes)
    collection.compact()
    collection.close()


def test_concurrent_first_pins_share_one_entry_and_keep_the_files() raises:
    var collection = _collection("pins")
    var manifest = load_manifest(collection._path, 1)
    var pins = ArcPointer(GenerationPinRegistry(collection._path, 1))
    var ready = Atomic[DType.int64](0)
    var failures = Atomic[DType.int64](0)
    var generation = manifest.generation

    def pin(task: Int) {imm pins, imm generation, mut ready, mut failures}:
        try:
            pins[].pin(generation)
            _ = ready.fetch_add(1)
            var start = perf_counter_ns()
            while ready.load() < 2:
                if perf_counter_ns() - start > 5_000_000_000:
                    raise Error("concurrent pin timed out")
                sleep(0.0001)
        except error:
            print(String(error))
            _ = failures.fetch_add(1)

    for attempt in range(16):
        ready.store(0)
        parallelize(pin, 2, 2)
        assert_equal(failures.load(), 0)
        assert_equal(pins[].active_count(), 2)
        assert_equal(len(pins[]._pins), 1)
        if attempt < 15:
            pins[].unpin(generation)
            pins[].unpin(generation)
    collection.compact()
    collection.close()
    pins[].unpin(generation)
    assert_equal(pins[].active_count(), 1)
    for index in range(len(manifest.segments)):
        assert_true(path_exists(collection._path + "/" + manifest.segments[index].name))
    pins[].unpin(generation)
    assert_equal(pins[].active_count(), 0)
    for index in range(len(manifest.segments)):
        assert_false(path_exists(collection._path + "/" + manifest.segments[index].name))
    assert_equal(pins[].cleanup_error(), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
