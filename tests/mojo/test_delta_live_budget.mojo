from akasha.index.segmented_hnsw import _should_scan_delta
from std.testing import assert_true, assert_false, TestSuite


def test_live_vector_budget_and_validation() raises:
    # The same physical tape has less scoring work when old rows are inactive.
    assert_true(_should_scan_delta(1, 1075, 819, 1536, 48, 32))
    assert_false(_should_scan_delta(1, 1075, 1075, 1536, 48, 32))
    assert_true(_should_scan_delta(1, 2048, 1024, 1536, 48, 128))
    assert_false(_should_scan_delta(1, 2048, 1024, 1537, 48, 128))
    assert_true(_should_scan_delta(1, 1024, 512, 3072, 48, 128))
    assert_false(_should_scan_delta(1, 1024, 512, 3073, 48, 128))
    assert_false(_should_scan_delta(1, 1024, 1025, 1, 48, 128))
    assert_false(_should_scan_delta(0, 1075, 819, 1536, 48, 32))
    for invalid in [0, -1, Int.MIN]:
        assert_false(_should_scan_delta(invalid, 1075, 819, 1536, 48, 32))
        assert_false(_should_scan_delta(1, invalid, 819, 1536, 48, 32))
        assert_false(_should_scan_delta(1, 1075, invalid, 1536, 48, 32))
        assert_false(_should_scan_delta(1, 1075, 819, invalid, 48, 32))
        assert_false(_should_scan_delta(1, 1075, 819, 1536, invalid, 32))
        assert_false(_should_scan_delta(1, 1075, 819, 1536, 48, invalid))
    assert_false(_should_scan_delta(1, 1, Int.MAX, 1, Int.MAX, Int.MAX))
    assert_false(_should_scan_delta(1, Int.MAX, 1, 1, Int.MAX, Int.MAX))
    assert_false(_should_scan_delta(1, 1, 1, Int.MAX, Int.MAX, Int.MAX))
    assert_true(_should_scan_delta(Int.MAX, 2048, 1024, 1, Int.MAX, Int.MAX))


def test_history_and_breadth_stay_bounded() raises:
    assert_true(_should_scan_delta(1, 1024, 1, 1, 48, 128))
    assert_false(_should_scan_delta(1, 1025, 1, 1, 48, 128))
    assert_true(_should_scan_delta(1, 1200, 600, 1, 48, 128))
    assert_false(_should_scan_delta(1, 1201, 600, 1, 48, 128))
    assert_true(_should_scan_delta(1, 2048, 1024, 1, 16, 128))
    assert_false(_should_scan_delta(1, 2049, 1024, 1, 48, 128))
    assert_false(_should_scan_delta(1, 2048, 1024, 1, 16, 127))
    # Known low-ef/all-live regressions remain outside the scan policy.
    assert_false(_should_scan_delta(1, 1024, 1024, 1536, 48, 10))
    assert_false(_should_scan_delta(1, 4096, 4096, 1536, 48, 32))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
