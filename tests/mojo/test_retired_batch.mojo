from akasha.storage.file_leases import _lock
from akasha.storage.filesystem import atomic_replace, ensure_directory, path_exists, remove_file_if_exists, write_file_sync
from akasha.storage.retired_files import RetiredFileQueue, reclaim_retired_batch
from std.ffi import c_int, external_call
from std.memory import ArcPointer
from std.os import listdir
from std.testing import assert_equal, assert_false, assert_raises, assert_true, TestSuite
from std.utils import BlockingScopedLock, BlockingSpinLock


def reset(path: String) raises:
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)


def test_detached_io_preserves_newly_enqueued_paths() raises:
    var path = String("/tmp/akasha-reclaim-detached-queue")
    reset(path)
    write_file_sync(path + "/first", [UInt8(1)])
    write_file_sync(path + "/later", [UInt8(2)])
    var shared = RetiredFileQueue()
    shared.enqueue([path + "/first"])
    var pending = shared.detach()
    assert_equal(len(shared._files), 0)
    shared.enqueue([path + "/later"])
    pending.reclaim(path)
    shared.restore(pending)
    assert_false(path_exists(path + "/first"))
    assert_true(path_exists(path + "/later"))
    assert_equal(len(shared._files), 1)
    shared.reclaim(path)
    assert_false(path_exists(path + "/later"))


def test_lease_deferral_is_restored_and_retried() raises:
    var path = String("/tmp/akasha-reclaim-detached-lease")
    reset(path)
    write_file_sync(path + "/leased", [UInt8(1)])
    write_file_sync(path + "/free", [UInt8(2)])
    var lease = open(path + "/leased", "r")
    assert_true(_lock(lease, False))
    var shared = ArcPointer(RetiredFileQueue())
    var writer = ArcPointer(BlockingSpinLock())
    shared[].enqueue([path + "/leased", path + "/free"])
    reclaim_retired_batch(path, shared, writer)
    assert_true(path_exists(path + "/leased"))
    assert_false(path_exists(path + "/free"))
    assert_equal(len(shared[]._files), 1)
    lease.close()
    reclaim_retired_batch(path, shared, writer)
    assert_false(path_exists(path + "/leased"))
    assert_equal(len(shared[]._files), 0)


def test_partial_unlink_failure_restores_the_full_retry_batch() raises:
    var path = String("/tmp/akasha-reclaim-detached-failure")
    reset(path)
    write_file_sync(path + "/first", [UInt8(1)])
    ensure_directory(path + "/bad")
    write_file_sync(path + "/last", [UInt8(2)])
    var shared = ArcPointer(RetiredFileQueue())
    var writer = ArcPointer(BlockingSpinLock())
    shared[].enqueue([path + "/first", path + "/bad", path + "/last"])
    with assert_raises(contains="unlink"):
        reclaim_retired_batch(path, shared, writer)
    assert_false(path_exists(path + "/first"))
    assert_true(path_exists(path + "/last"))
    assert_equal(len(shared[]._files), 3)
    var bad = path + "/bad"
    assert_equal(external_call["rmdir", c_int](bad.as_c_string_slice()), c_int(0))
    # The writer lock must have been released on the failure path too.
    with BlockingScopedLock(writer[]):
        write_file_sync(path + "/later", [UInt8(3)])
        shared[].enqueue([path + "/later"])
    reclaim_retired_batch(path, shared, writer)
    assert_equal(len(shared[]._files), 0)
    assert_false(path_exists(path + "/last"))
    assert_false(path_exists(path + "/later"))


def test_open_failure_keeps_the_shared_queue() raises:
    var path = String("/tmp/akasha-reclaim-detached-open-failure")
    reset(path)
    assert_equal(external_call["rmdir", c_int](path.as_c_string_slice()), c_int(0))
    var shared = ArcPointer(RetiredFileQueue())
    var writer = ArcPointer(BlockingSpinLock())
    shared[].enqueue([path + "/first"])
    with assert_raises():
        reclaim_retired_batch(path, shared, writer)
    assert_equal(len(shared[]._files), 1)
    ensure_directory(path)
    write_file_sync(path + "/first", [UInt8(1)])
    reclaim_retired_batch(path, shared, writer)
    assert_equal(len(shared[]._files), 0)
    assert_false(path_exists(path + "/first"))


def test_detached_io_stays_in_the_opened_directory() raises:
    var path = String("/tmp/akasha-reclaim-detached-directory")
    var moved = path + "-moved"
    reset(path)
    reset(moved)
    write_file_sync(path + "/old", [UInt8(1)])
    var handle = open(path, "r")
    var pending = RetiredFileQueue()
    pending.enqueue([path + "/old"])
    atomic_replace(path, moved)
    ensure_directory(path)
    write_file_sync(path + "/old", [UInt8(2)])
    pending._reclaim_from_handle(path, handle)
    assert_false(path_exists(moved + "/old"))
    assert_true(path_exists(path + "/old"))
    assert_equal(len(pending._files), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
