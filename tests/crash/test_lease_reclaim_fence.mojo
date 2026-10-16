from std.python import Python
from std.testing import assert_equal, TestSuite


def test_directory_sync_failure_keeps_retired_inputs_until_retry() raises:
    var subprocess = Python.import_module("subprocess")
    var sys = Python.import_module("sys")
    var args = Python.list()
    args.append(sys.executable)
    args.append("tests/crash/run_lease_reclaim_fence.py")
    var result = subprocess.run(args, capture_output=True, text=True, timeout=180)
    assert_equal(
        Int(py=result.returncode), 0, String(py=result.stdout + result.stderr)
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
