from akasha.storage.compaction import CompactionPolicy
from akasha.storage.manifest import Manifest, SegmentDescriptor
from std.testing import assert_equal, assert_raises, TestSuite


def _manifest(levels: List[Int]) raises -> Manifest:
    var descriptors = List[SegmentDescriptor]()
    for index in range(len(levels)):
        var min_sequence = UInt64(index + 1)
        if index == 0:
            min_sequence = 0
        descriptors.append(
            SegmentDescriptor(
                levels[index],
                min_sequence,
                UInt64(index + 1),
                UInt32(index + 1),
                "segment-" + String(index) + ".bin",
            )
        )
    return Manifest.with_segments(1, 1, UInt64(len(levels)), descriptors^)


def test_compaction_policy_counts_only_level_zero_segments() raises:
    var policy = CompactionPolicy(3)
    var below = _manifest([1, 0, 0])
    var ready = _manifest([1, 0, 0, 0])

    assert_equal(policy.level_zero_count(below), 2)
    assert_equal(policy.should_compact(below), False)
    assert_equal(policy.should_compact(ready), True)


def test_compaction_policy_rejects_non_positive_threshold() raises:
    with assert_raises():
        _ = CompactionPolicy(0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
