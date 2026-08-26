from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_scratch import HnswSearchScratch
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _item(slot: Int, id: Int, distance: Float32) -> HnswHeapItem:
    return HnswHeapItem(UInt32(slot), id, distance)


def test_initialization_and_first_begin_prepare_empty_scratch() raises:
    var scratch = HnswSearchScratch()

    assert_equal(len(scratch.visited_epochs), 0)
    assert_equal(scratch.epoch, UInt32(0))
    assert_true(scratch.candidates.is_empty())
    assert_true(scratch.results.is_empty())

    scratch.begin(4, 8)
    assert_equal(len(scratch.visited_epochs), 4)
    assert_equal(scratch.epoch, UInt32(1))
    assert_true(scratch.candidates.is_empty())
    assert_true(scratch.results.is_empty())


def test_visit_marks_only_the_first_visit_in_current_epoch() raises:
    var scratch = HnswSearchScratch()
    scratch.begin(3, 4)

    assert_true(scratch.visit(UInt32(1)))
    assert_false(scratch.visit(UInt32(1)))
    assert_true(scratch.visit(UInt32(0)))
    assert_false(scratch.visit(UInt32(0)))


def test_new_begin_makes_previous_marks_logically_unvisited() raises:
    var scratch = HnswSearchScratch()
    scratch.begin(3, 4)
    assert_true(scratch.visit(UInt32(2)))
    var old_word = scratch.visited_epochs[2]

    scratch.begin(3, 4)
    assert_equal(scratch.epoch, UInt32(2))
    assert_equal(scratch.visited_epochs[2], old_word)
    assert_true(scratch.visit(UInt32(2)))
    assert_false(scratch.visit(UInt32(2)))


def test_zero_slots_and_invalid_inputs_are_checked() raises:
    var scratch = HnswSearchScratch()
    scratch.begin(0, 1)
    assert_equal(len(scratch.visited_epochs), 0)
    with assert_raises():
        _ = scratch.visit(UInt32(0))
    with assert_raises():
        scratch.begin(-1, 1)
    with assert_raises():
        scratch.begin(1, 0)
    with assert_raises():
        scratch.begin(1, -1)
    with assert_raises():
        scratch.ensure_slot_count(-1)


def test_growth_preserves_marks_and_does_not_shrink() raises:
    var scratch = HnswSearchScratch()
    scratch.begin(2, 4)
    assert_true(scratch.visit(UInt32(1)))
    var current_epoch = scratch.epoch

    scratch.ensure_slot_count(4)
    assert_equal(len(scratch.visited_epochs), 4)
    assert_equal(scratch.epoch, current_epoch)
    assert_false(scratch.visit(UInt32(1)))
    assert_true(scratch.visit(UInt32(2)))
    assert_true(scratch.visit(UInt32(3)))

    scratch.ensure_slot_count(2)
    assert_equal(len(scratch.visited_epochs), 4)
    assert_equal(scratch.epoch, current_epoch)
    assert_false(scratch.visit(UInt32(3)))


def test_epoch_wrap_clears_words_once_and_restarts_at_one() raises:
    var scratch = HnswSearchScratch()
    scratch.begin(3, 4)
    assert_true(scratch.visit(UInt32(0)))
    assert_true(scratch.visit(UInt32(2)))
    scratch._force_epoch_for_test(UInt32.MAX)

    scratch.begin(3, 4)
    assert_equal(scratch.epoch, UInt32(1))
    for index in range(3):
        assert_equal(scratch.visited_epochs[index], UInt32(0))

    assert_true(scratch.visit(UInt32(0)))
    assert_false(scratch.visit(UInt32(0)))
    assert_true(scratch.visit(UInt32(2)))


def test_begin_clears_and_reuses_both_heaps() raises:
    var scratch = HnswSearchScratch()
    scratch.begin(4, 3)
    scratch.candidates.push(_item(1, 10, 2.0))
    scratch.results.offer(_item(2, 20, 3.0), 3)
    assert_equal(len(scratch.candidates), 1)
    assert_equal(len(scratch.results), 1)

    scratch.begin(4, 9)
    assert_true(scratch.candidates.is_empty())
    assert_true(scratch.results.is_empty())
    scratch.candidates.push(_item(3, 30, -1.0))
    scratch.results.offer(_item(0, 40, 1.0), 9)
    assert_equal(scratch.candidates.pop().slot, UInt32(3))
    assert_equal(scratch.results.pop_worst().slot, UInt32(0))


def test_begin_bounds_old_capacity_and_large_ordinal_without_growing() raises:
    var scratch = HnswSearchScratch()
    scratch.begin(8, 4)
    assert_true(scratch.visit(UInt32(7)))
    scratch.begin(4, 4)
    with assert_raises():
        _ = scratch.visit(UInt32(7))
    with assert_raises():
        _ = scratch.visit(UInt32.MAX)
    assert_equal(len(scratch.visited_epochs), 8)


def test_many_query_resets_keep_storage_and_use_epoch_marks() raises:
    var scratch = HnswSearchScratch()
    scratch.begin(8, 16)
    var storage_length = len(scratch.visited_epochs)
    assert_equal(scratch.visited_epochs[6], UInt32(0))

    for _ in range(1_000):
        scratch.begin(8, 16)
        assert_true(scratch.visit(UInt32(3)))
        assert_false(scratch.visit(UInt32(3)))
        assert_equal(len(scratch.visited_epochs), storage_length)
        assert_equal(scratch.visited_epochs[3], scratch.epoch)
        assert_equal(scratch.visited_epochs[6], UInt32(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
