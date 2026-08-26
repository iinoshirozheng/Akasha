from akasha.storage.filesystem import (
    _DurableDirectoryOps,
    _ensure_durable_directory_with_ops,
    ensure_directory,
    ensure_durable_directory,
    path_exists,
)
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_raises, TestSuite


struct _RecordingDirectoryOps(_DurableDirectoryOps):
    var existing: Bool
    var made: Bool
    var sync_attempts: Int
    var fail_sync_at: Int

    def __init__(
        out self, existing: Bool = False, fail_sync_at: Int = 0
    ):
        self.existing = existing
        self.made = False
        self.sync_attempts = 0
        self.fail_sync_at = fail_sync_at

    def exists(self, path: String) -> Bool:
        return self.existing

    def make(mut self, path: String) raises:
        self.made = True
        self.existing = True

    def sync(mut self, path: String) raises:
        self.sync_attempts += 1
        if self.sync_attempts == self.fail_sync_at:
            raise Error("injected directory sync failure")


def test_new_directory_syncs_itself_and_parent_once() raises:
    var ops = _RecordingDirectoryOps()

    var created = _ensure_durable_directory_with_ops(
        "/tmp/parent/collection", "/tmp/parent", ops
    )

    assert_equal(created, True)
    assert_equal(ops.made, True)
    assert_equal(ops.sync_attempts, 2)


def test_existing_directory_requires_no_creation_sync() raises:
    var ops = _RecordingDirectoryOps(existing=True)

    var created = _ensure_durable_directory_with_ops(
        "/tmp/parent/collection", "/tmp/parent", ops
    )

    assert_equal(created, False)
    assert_equal(ops.made, False)
    assert_equal(ops.sync_attempts, 0)


def test_parent_sync_failure_propagates_after_creation() raises:
    var ops = _RecordingDirectoryOps(fail_sync_at=2)

    with assert_raises():
        _ = _ensure_durable_directory_with_ops(
            "/tmp/parent/collection", "/tmp/parent", ops
        )

    assert_equal(ops.made, True)
    assert_equal(ops.sync_attempts, 2)


def test_real_durable_directory_reports_created_then_existing() raises:
    var process_id = external_call["getpid", c_int]()
    var parent = String("/tmp/akasha-durable-directory-", Int(process_id))
    var child = parent + "/collection"
    ensure_directory(parent)
    assert_equal(path_exists(child), False)

    assert_equal(ensure_durable_directory(child), True)
    assert_equal(path_exists(child), True)
    assert_equal(ensure_durable_directory(child), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
