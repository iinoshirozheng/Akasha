from akasha.storage.filesystem import ensure_directory
from akasha.storage.lock import CollectionLock
from std.testing import assert_raises, TestSuite


def test_lock_rejects_second_owner_and_releases_on_close() raises:
    var directory = String("/tmp/akasha-phase5-lock-close")
    ensure_directory(directory)
    var first = CollectionLock.acquire(directory + "/collection.lock")

    with assert_raises():
        _ = CollectionLock.acquire(directory + "/collection.lock")

    first.close()
    var second = CollectionLock.acquire(directory + "/collection.lock")
    second.close()


def _acquire_and_drop(path: String) raises:
    var lock = CollectionLock.acquire(path)


def test_lock_releases_when_owner_is_destroyed() raises:
    var directory = String("/tmp/akasha-phase5-lock-drop")
    ensure_directory(directory)
    var path = directory + "/collection.lock"
    _acquire_and_drop(path)
    var next = CollectionLock.acquire(path)
    next.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
