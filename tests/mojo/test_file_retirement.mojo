from akasha import PersistentCollection
from akasha.storage.filesystem import (
    atomic_replace,
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from std.os import listdir
from std.python import Python
from std.sys.arg import argv
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(path: String) raises:
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)


def test_last_snapshot_release_reclaims_after_collection_close() raises:
    var path = String("/tmp/akasha-56-last-file-release")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    var before = load_manifest(path, 1)
    var snapshot = collection.snapshot()
    collection.upsert(2, [2.0])
    collection.rebuild_hnsw()
    collection.flush()
    collection.compact()
    # Retirement requires a replacement; ordinary v5 flush retains the base.
    assert_true(
        load_manifest(path, 1).hnsw_name.value() != before.hnsw_name.value()
    )
    collection.close()
    assert_true(path_exists(path + "/" + before.segments[0].name))
    assert_true(path_exists(path + "/" + before.segments[0].sparse_name))
    assert_true(path_exists(path + "/" + before.hnsw_name.value()))
    assert_equal(snapshot.get(1).value().vector[0], Float32(1))
    snapshot.close()
    assert_false(path_exists(path + "/" + before.segments[0].name))
    assert_false(path_exists(path + "/" + before.segments[0].sparse_name))
    assert_false(path_exists(path + "/" + before.hnsw_name.value()))
    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.get(2).value().vector[0], Float32(2))
    reopened.close()


def test_snapshot_lease_survives_a_replacement_writer_and_its_close() raises:
    var path = String("/tmp/akasha-56-file-lease-reopen")
    _reset(path)
    var first = PersistentCollection.open(path, 1)
    first.upsert(1, [1.0])
    first.flush()
    var before = load_manifest(path, 1)
    var snapshot = first.snapshot()
    first.close()
    var second = PersistentCollection.open(path, 1)
    second.upsert(2, [2.0])
    second.rebuild_hnsw()
    second.flush()
    second.compact()
    # Retirement requires a replacement; ordinary v5 flush retains the base.
    assert_true(
        load_manifest(path, 1).hnsw_name.value() != before.hnsw_name.value()
    )
    assert_true(path_exists(path + "/" + before.segments[0].name))
    assert_true(path_exists(path + "/" + before.hnsw_name.value()))
    second.close()
    assert_equal(snapshot.get(1).value().vector[0], Float32(1))
    snapshot.close()
    assert_false(path_exists(path + "/" + before.segments[0].name))
    assert_false(path_exists(path + "/" + before.hnsw_name.value()))


def test_two_collection_instances_release_only_the_last_file_lease() raises:
    var path = String("/tmp/akasha-56-two-file-leases")
    _reset(path)
    var first = PersistentCollection.open(path, 1)
    first.upsert(1, [1.0])
    first.flush()
    var before = load_manifest(path, 1)
    var old = first.snapshot()
    first.close()
    var second = PersistentCollection.open(path, 1)
    var sibling = second.snapshot()
    second.upsert(2, [2.0])
    second.rebuild_hnsw()
    second.flush()
    second.compact()
    # Retirement requires a replacement; ordinary v5 flush retains the base.
    assert_true(
        load_manifest(path, 1).hnsw_name.value() != before.hnsw_name.value()
    )
    second.close()
    old.close()
    assert_true(path_exists(path + "/" + before.segments[0].name))
    assert_true(path_exists(path + "/" + before.hnsw_name.value()))
    assert_equal(sibling.get(1).value().vector[0], Float32(1))
    sibling.close()
    assert_false(path_exists(path + "/" + before.segments[0].name))
    assert_false(path_exists(path + "/" + before.hnsw_name.value()))


def test_cleanup_stays_in_its_original_directory_after_path_replacement() raises:
    var path = String("/tmp/akasha-56-lease-directory")
    var moved = path + "-moved"
    _reset(path)
    _reset(moved)
    var first = PersistentCollection.open(path, 1)
    first.upsert(1, [1.0])
    first.flush()
    var before = load_manifest(path, 1)
    var snapshot = first.snapshot()
    first.close()
    atomic_replace(path, moved)
    var second = PersistentCollection.open(moved, 1)
    second.upsert(2, [2.0])
    second.flush()
    second.compact()
    second.close()
    var replacement = PersistentCollection.open(path, 1)
    replacement.upsert(1, [99.0])
    replacement.flush()
    var replacement_bytes = read_file_bytes(
        path + "/" + before.segments[0].name
    )
    snapshot.close()
    assert_false(path_exists(moved + "/" + before.segments[0].name))
    assert_equal(
        read_file_bytes(path + "/" + before.segments[0].name), replacement_bytes
    )
    assert_equal(replacement.get(1).value().vector[0], Float32(99))
    replacement.close()


def test_failed_file_capture_does_not_leave_a_pin() raises:
    var path = String("/tmp/akasha-56-lease-capture-failure")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    var manifest = load_manifest(path, 1)
    var name = path + "/" + manifest.segments[0].name
    var bytes = read_file_bytes(name)
    remove_file_if_exists(name)
    with assert_raises():
        _ = collection.snapshot()
    assert_equal(collection._pins[].active_count(), 0)
    write_file_sync(name, bytes)
    var snapshot = collection.snapshot()
    assert_equal(snapshot.get(1).value().vector[0], Float32(1))
    snapshot.close()
    collection.close()


def test_corrupt_manifest_defers_last_release_cleanup_and_records_error() raises:
    var path = String("/tmp/akasha-56-lease-cleanup-failure")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    var before = load_manifest(path, 1)
    var snapshot = collection.snapshot()
    collection.upsert(2, [2.0])
    collection.flush()
    collection.compact()
    var manifest_bytes = read_file_bytes(path + "/manifest.bin")
    write_file_sync(path + "/manifest.bin", [UInt8(1)])
    snapshot.close()
    assert_true(collection._pins[].cleanup_error().byte_length() > 0)
    assert_true(path_exists(path + "/" + before.segments[0].name))
    write_file_sync(path + "/manifest.bin", manifest_bytes)
    collection.flush()
    assert_false(path_exists(path + "/" + before.segments[0].name))
    collection.close()


def test_captured_compaction_retains_writer_ownership_until_discard() raises:
    var path = String("/tmp/akasha-56-compaction-file-operation")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    collection.upsert(2, [2.0])
    collection.flush()
    var inputs = collection._begin_compaction()
    assert_true(Bool(inputs))
    collection.close()
    with assert_raises(contains="already open"):
        _ = PersistentCollection.open(path, 1)
    var output = collection._build_compaction(inputs.value())
    with assert_raises(contains="closed"):
        _ = collection._finish_compaction(inputs.value(), output)
    assert_false(path_exists(path + "/" + output.segment_name))
    assert_false(path_exists(path + "/" + output.sparse_name))
    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.get(2).value().vector[0], Float32(2))
    reopened.close()


def test_reopen_reclaims_unreferenced_job_outputs_at_any_generation() raises:
    var path = String("/tmp/akasha-56-all-job-orphans")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    collection.upsert(2, [2.0])
    collection.flush()
    collection.rebuild_hnsw()
    collection.flush()
    var manifest = load_manifest(path, 1)
    collection.close()
    var orphan_names = List[String]()
    for generation in [UInt64(1), manifest.generation, manifest.generation + 1]:
        for prefix in ["hnsw-2-", "segment-compact-", "sparse-compact-"]:
            var name = prefix + String(generation) + "-777.bin"
            orphan_names.append(name.copy())
            write_file_sync(path + "/" + name, [UInt8(1)])
    var reopened = PersistentCollection.open(path, 1)
    for name in orphan_names:
        assert_false(path_exists(path + "/" + name))
    assert_true(path_exists(path + "/" + manifest.hnsw_name.value()))
    assert_equal(reopened.get(2).value().vector[0], Float32(2))
    reopened.close()


def _child_reader(path: String) raises:
    var collection = PersistentCollection.open(path, 1)
    var snapshot = collection.snapshot()
    collection.close()
    write_file_sync(path + "/reader.ready", [UInt8(1)])
    var time = Python.import_module("time")
    var deadline = Float64(py=time.monotonic()) + 60.0
    while not path_exists(path + "/reader.release"):
        if Float64(py=time.monotonic()) > deadline:
            raise Error("reader release handshake timed out")
        time.sleep(0.01)
    assert_equal(snapshot.get(1).value().vector[0], Float32(1))
    snapshot.close()


def test_file_lease_survives_an_independent_reader_process() raises:
    var path = String("/tmp/akasha-56-process-file-lease")
    _reset(path)
    var first = PersistentCollection.open(path, 1)
    first.upsert(1, [1.0])
    first.flush()
    var captured = load_manifest(path, 1)
    first.close()

    var subprocess = Python.import_module("subprocess")
    var time = Python.import_module("time")
    var args = Python.list()
    for arg in ["mojo", "run", "-I", "src", argv()[0], "lease-reader", path]:
        args.append(arg)
    var child = subprocess.Popen(
        args, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    try:
        var deadline = Float64(py=time.monotonic()) + 60.0
        while not path_exists(path + "/reader.ready"):
            if Bool(py=child.poll() != Python.none()):
                var output = child.communicate()
                raise Error("reader failed: " + String(py=output[1].decode()))
            if Float64(py=time.monotonic()) > deadline:
                raise Error("reader capture handshake timed out")
            time.sleep(0.01)
        var writer = PersistentCollection.open(path, 1)
        writer.upsert(2, [2.0])
        writer.rebuild_hnsw()
        writer.flush()
        writer.compact()
        # Retirement requires a replacement; ordinary v5 flush retains the base.
        assert_true(
            load_manifest(path, 1).hnsw_name.value()
            != captured.hnsw_name.value()
        )
        writer.close()
        for name in [
            captured.segments[0].name,
            captured.segments[0].sparse_name,
            captured.hnsw_name.value(),
        ]:
            assert_true(path_exists(path + "/" + name))
        write_file_sync(path + "/reader.release", [UInt8(1)])
        var output = child.communicate(timeout=60)
        if Int(py=child.returncode) != 0:
            raise Error(
                "reader release failed: " + String(py=output[1].decode())
            )
        for name in [
            captured.segments[0].name,
            captured.segments[0].sparse_name,
            captured.hnsw_name.value(),
        ]:
            assert_false(path_exists(path + "/" + name))
    except error:
        child.kill()
        _ = child.communicate()
        raise error^


def main() raises:
    var args = argv()
    if len(args) == 3 and args[1] == "lease-reader":
        _child_reader(args[2])
        return
    TestSuite.discover_tests[__functions_in_module()]().run()
