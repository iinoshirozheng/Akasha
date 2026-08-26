from akasha.index.hnsw_heap import (
    CandidateMinHeap,
    HnswHeapItem,
    ResultMaxHeap,
)
from std.testing import (
    assert_equal,
    assert_raises,
    assert_true,
    TestSuite,
)


def _item(slot: Int, id: Int, distance: Float32) -> HnswHeapItem:
    return HnswHeapItem(UInt32(slot), id, distance)


def _assert_item(
    actual: HnswHeapItem,
    slot: Int,
    id: Int,
    distance: Float32,
) raises:
    assert_equal(actual.slot, UInt32(slot))
    assert_equal(actual.id, id)
    assert_equal(actual.distance, distance)


def _is_model_better(lhs: HnswHeapItem, rhs: HnswHeapItem) -> Bool:
    if lhs.distance == rhs.distance:
        return lhs.id < rhs.id
    return lhs.distance < rhs.distance


def _sort_model_best_first(mut values: List[HnswHeapItem]):
    # Deliberately simple test oracle, independent of the production heap.
    for end in range(len(values) - 1, 0, -1):
        for index in range(end):
            if _is_model_better(values[index + 1], values[index]):
                values.swap_elements(index, index + 1)


def test_empty_heaps_raise_and_report_empty() raises:
    var candidates = CandidateMinHeap()
    var results = ResultMaxHeap()

    assert_equal(len(candidates), 0)
    assert_true(candidates.is_empty())
    assert_equal(len(results), 0)
    assert_true(results.is_empty())
    with assert_raises():
        _ = candidates.peek()
    with assert_raises():
        _ = candidates.pop()
    with assert_raises():
        _ = results.peek_worst()
    with assert_raises():
        _ = results.pop_worst()


def test_candidate_min_heap_orders_by_distance_then_ascending_id() raises:
    var heap = CandidateMinHeap()
    heap.reserve(7)
    heap.push(_item(40, 40, 3.0))
    heap.push(_item(30, 30, -2.0))
    heap.push(_item(20, 20, 1.0))
    heap.push(_item(10, 10, 1.0))
    heap.push(_item(50, 50, -2.0))
    heap.push(_item(60, 60, 3.0e38))
    heap.push(_item(70, 70, -3.0e38))

    _assert_item(heap.peek(), 70, 70, -3.0e38)
    _assert_item(heap.pop(), 70, 70, -3.0e38)
    _assert_item(heap.pop(), 30, 30, -2.0)
    _assert_item(heap.pop(), 50, 50, -2.0)
    _assert_item(heap.pop(), 10, 10, 1.0)
    _assert_item(heap.pop(), 20, 20, 1.0)
    _assert_item(heap.pop(), 40, 40, 3.0)
    _assert_item(heap.pop(), 60, 60, 3.0e38)
    assert_true(heap.is_empty())


def test_result_max_heap_exposes_worst_first() raises:
    var heap = ResultMaxHeap()
    heap.reserve(6)
    heap.offer(_item(1, 30, 2.0), 6)
    heap.offer(_item(2, 10, 2.0), 6)
    heap.offer(_item(3, 20, -4.0), 6)
    heap.offer(_item(4, 40, 7.0), 6)
    heap.offer(_item(5, 50, -4.0), 6)
    heap.offer(_item(6, 60, 3.0e38), 6)

    _assert_item(heap.peek_worst(), 6, 60, 3.0e38)
    _assert_item(heap.pop_worst(), 6, 60, 3.0e38)
    _assert_item(heap.pop_worst(), 4, 40, 7.0)
    _assert_item(heap.pop_worst(), 1, 30, 2.0)
    _assert_item(heap.pop_worst(), 2, 10, 2.0)
    _assert_item(heap.pop_worst(), 5, 50, -4.0)
    _assert_item(heap.pop_worst(), 3, 20, -4.0)


def test_result_offer_retains_only_best_capacity() raises:
    var heap = ResultMaxHeap()
    heap.reserve(3)
    heap.offer(_item(80, 80, 8.0), 3)
    heap.offer(_item(30, 30, 3.0), 3)
    heap.offer(_item(50, 50, 5.0), 3)
    heap.offer(_item(60, 60, 6.0), 3)  # rejected
    heap.offer(_item(20, 20, 2.0), 3)  # replaces distance 8
    heap.offer(_item(10, 10, 5.0), 3)  # same distance, better ID
    heap.offer(_item(70, 70, 5.0), 3)  # same distance, worse ID

    assert_equal(len(heap), 3)
    var sorted = heap.take_sorted_best()
    assert_equal(len(sorted), 3)
    _assert_item(sorted[0], 20, 20, 2.0)
    _assert_item(sorted[1], 30, 30, 3.0)
    _assert_item(sorted[2], 10, 10, 5.0)
    # take_sorted_best intentionally drains the heap for scratch reuse.
    assert_true(heap.is_empty())


def test_result_offer_rejects_non_positive_capacity() raises:
    var heap = ResultMaxHeap()
    with assert_raises():
        heap.offer(_item(1, 1, 1.0), 0)
    with assert_raises():
        heap.offer(_item(1, 1, 1.0), -1)
    assert_true(heap.is_empty())


def test_clear_reserve_and_reuse_preserve_item_associations() raises:
    var candidates = CandidateMinHeap()
    candidates.reserve(32)
    candidates.push(_item(99, 4, 9.0))
    candidates.clear()
    assert_true(candidates.is_empty())
    candidates.push(_item(17, -8, -1.5))
    _assert_item(candidates.pop(), 17, -8, -1.5)

    var results = ResultMaxHeap()
    results.reserve(32)
    results.offer(_item(91, 4, 9.0), 2)
    results.clear()
    assert_true(results.is_empty())
    results.offer(_item(71, -8, -1.5), 2)
    _assert_item(results.peek_worst(), 71, -8, -1.5)


def test_candidate_heap_matches_sorted_model_for_many_operations() raises:
    var heap = CandidateMinHeap()
    heap.reserve(1_000)
    var model = List[HnswHeapItem](capacity=1_000)

    for index in range(1_000):
        # IDs are a permutation; distances deliberately repeat heavily.
        var id = (index * 197) % 1_000 - 500
        var distance = Float32((index * 37) % 41 - 20)
        var value = _item(index, id, distance)
        heap.push(value)
        model.append(value.copy())

    _sort_model_best_first(model)
    for index in range(1_000):
        var actual = heap.pop()
        _assert_item(
            actual,
            Int(model[index].slot),
            model[index].id,
            model[index].distance,
        )
    assert_true(heap.is_empty())


def test_result_heap_matches_sorted_model_with_repeated_equal_distances() raises:
    var heap = ResultMaxHeap()
    heap.reserve(1_000)
    var model = List[HnswHeapItem](capacity=1_000)

    for index in range(1_000):
        var id = (index * 197) % 1_000 - 500
        var distance = Float32((index * 13) % 17 - 8)
        var value = _item(index, id, distance)
        heap.offer(value, 1_000)
        model.append(value.copy())

    _sort_model_best_first(model)
    var actual = heap.take_sorted_best()
    assert_equal(len(actual), len(model))
    for index in range(len(model)):
        _assert_item(
            actual[index],
            Int(model[index].slot),
            model[index].id,
            model[index].distance,
        )
    assert_true(heap.is_empty())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
