from akasha import PersistentCollection
from akasha.common.config import CollectionConfig
from akasha.storage.filesystem import ensure_directory, path_exists, remove_file_if_exists, write_file_sync
from akasha.storage.manifest import load_manifest
from max.algorithm import parallelize
from std.atomic import Atomic
from std.ffi import c_int, external_call
from std.os import listdir
from std.python import Python
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.time import perf_counter_ns, sleep


def test_close_can_finish_during_reclaim_but_new_writer_waits_for_source_owner() raises:
    var path = String("/tmp/akasha-reclaim-close-race")
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)
    var collection = PersistentCollection.open_with_config(
        path, CollectionConfig.defaults(1), maintenance_library_path=""
    )
    collection.upsert(1, [1.0])
    collection.flush()
    collection.upsert(2, [2.0])
    collection.flush()
    var inputs = collection._begin_compaction()
    assert_true(Bool(inputs))
    var generation = inputs.value().manifest.generation
    var output = collection._build_compaction(inputs.value())
    var fifo = path + "/reclaim.fifo"
    assert_equal(external_call["mkfifo", c_int](fifo.as_c_string_slice(), c_int(384)), c_int(0))
    # Opening this obsolete test FIFO blocks until close has proved progress.
    assert_equal(len(collection._retired[]._files), 0)
    collection._retired[]._files.append(fifo.copy())
    var subprocess = Python.import_module("subprocess")
    var sys = Python.import_module("sys")
    var args = Python.list()
    args.append(sys.executable)
    args.append("-c")
    args.append("""
import errno, os, pathlib, sys, time
fifo, ready, timeout = map(pathlib.Path, sys.argv[1:])
deadline = time.monotonic() + 5
while not ready.exists() and time.monotonic() < deadline:
    time.sleep(.001)
if not ready.exists():
    timeout.write_text('writer lock blocked close')
deadline = time.monotonic() + 5
while True:
    try:
        fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
        os.close(fd)
        break
    except OSError as error:
        if error.errno != errno.ENXIO or time.monotonic() >= deadline:
            raise
        time.sleep(.001)
""")
    args.append(fifo)
    args.append(path + "/release.ready")
    args.append(path + "/release.timeout")
    var child = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    var failures = Atomic[DType.int64](0)
    var completed = Atomic[DType.int64](0)
    var locked_checks = Atomic[DType.int64](0)
    var lease_errors = Atomic[DType.int64](0)

    def finish_or_close(task: Int) {mut collection, mut inputs, mut output, path, generation, mut failures, mut completed, mut locked_checks, mut lease_errors}:
        if task == 0:
            try:
                if not collection._finish_compaction(inputs.value(), output):
                    _ = failures.fetch_add(1)
            except error:
                # Darwin rejects flock on FIFOs; Linux may allow it. The test
                # covers the ownership boundary for either I/O disposition.
                if "immutable file lease failed" in String(error):
                    _ = lease_errors.fetch_add(1)
                else:
                    _ = failures.fetch_add(1)
            _ = completed.fetch_add(1)
            return
        try:
            var deadline = perf_counter_ns() + 10_000_000_000
            while load_manifest(path, 1).generation == generation:
                if perf_counter_ns() > deadline:
                    raise Error("publication handshake timed out")
                sleep(0.001)
            collection.close()
            try:
                var other = PersistentCollection.open_with_config(
                    path, CollectionConfig.defaults(1), maintenance_library_path=""
                )
                other.close()
                _ = failures.fetch_add(1)
            except error:
                if "already open" in String(error):
                    _ = locked_checks.fetch_add(1)
                else:
                    _ = failures.fetch_add(1)
        except:
            _ = failures.fetch_add(1)
        try:
            write_file_sync(path + "/release.ready", [UInt8(1)])
        except:
            _ = failures.fetch_add(1)

    parallelize(finish_or_close, 2, 2)
    var child_output = child.communicate(timeout=15)
    assert_equal(Int(py=child.returncode), 0, String(py=child_output[1].decode()))
    assert_false(path_exists(path + "/release.timeout"))
    assert_equal(failures.load(), 0)
    assert_equal(completed.load(), 1)
    assert_equal(locked_checks.load(), 1)
    if lease_errors.load() > 0:
        assert_true(len(collection._retired[]._files) > 0)
    remove_file_if_exists(fifo)
    var reopened = PersistentCollection.open_with_config(
        path, CollectionConfig.defaults(1), maintenance_library_path=""
    )
    assert_equal(reopened.get(1).value().vector[0], Float32(1))
    assert_equal(reopened.get(2).value().vector[0], Float32(2))
    reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
