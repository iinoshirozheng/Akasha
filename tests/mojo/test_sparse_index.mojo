from akasha.index.sparse import SparseElement, SparseIndex
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_raises,
    TestSuite,
)


def test_sparse_dot_search_accumulates_postings_and_stable_ties() raises:
    var index = SparseIndex()
    index.upsert(2, [SparseElement(1, 1.0), SparseElement(3, 2.0)])
    index.upsert(1, [SparseElement(1, 1.0), SparseElement(2, 4.0)])
    index.upsert(3, [SparseElement(9, 5.0)])

    var results = index.search_dot(
        [SparseElement(1, 1.0), SparseElement(3, 1.0)], 3
    )

    assert_equal(len(results), 2)
    assert_equal(results[0].id, 2)
    assert_almost_equal(results[0].score, 3.0, atol=1.0e-6)
    assert_equal(results[1].id, 1)


def test_sparse_upsert_replaces_and_delete_removes_record() raises:
    var index = SparseIndex()
    index.upsert(1, [SparseElement(1, 2.0)])
    index.upsert(1, [SparseElement(2, 3.0)])
    assert_equal(len(index.search_dot([SparseElement(1, 1.0)], 2)), 0)
    assert_equal(index.search_dot([SparseElement(2, 1.0)], 2)[0].id, 1)
    index.delete(1)
    assert_equal(len(index.search_dot([SparseElement(2, 1.0)], 2)), 0)


def test_sparse_validation_rejects_invalid_terms_and_weights() raises:
    var index = SparseIndex()
    with assert_raises():
        index.upsert(1, List[SparseElement]())
    with assert_raises():
        index.upsert(1, [SparseElement(-1, 1.0)])
    with assert_raises():
        index.upsert(1, [SparseElement(2, 1.0), SparseElement(2, 2.0)])
    with assert_raises():
        index.upsert(1, [SparseElement(2, 0.0)])
    with assert_raises():
        _ = index.search_dot([SparseElement(1, 1.0)], 0)


def test_sparse_slot_moves_reinsertion_and_clone_independence() raises:
    var index = SparseIndex()
    for id in range(-32, 32):
        index.upsert(id, [SparseElement(0, 1.0), SparseElement(id + 33, 2.0)])
    for id in range(-32, 32, 2):
        index.delete(id)
        index.delete(id)
        assert_equal(index.contains(id), False)
        assert_equal(len(index.search_dot([SparseElement(id + 33, 1.0)], 1)), 0)
    var cloned = index.clone()
    for id in range(-31, 32, 2):
        assert_equal(index.search_dot([SparseElement(id + 33, 1.0)], 1)[0].id, id)
        index.upsert(id, [SparseElement(id + 100, 4.0)])
        assert_equal(cloned.search_dot([SparseElement(id + 33, 1.0)], 1)[0].id, id)
    for id in range(-32, 32, 2):
        index.upsert(id, [SparseElement(id + 33, 3.0)])
        assert_equal(index.search_dot([SparseElement(id + 33, 1.0)], 1)[0].score, 3.0)
    assert_equal(index.point_count(), 64)
    assert_equal(cloned.point_count(), 32)
    for id in range(-32, 32):
        index.delete(id)
    assert_equal(index.point_count(), 0)
    index.upsert(Int.MIN, [SparseElement(0, 1.0)])
    assert_equal(index.search_dot([SparseElement(0, 1.0)], 1)[0].id, Int.MIN)


def test_sparse_accumulation_keeps_query_order_after_slot_moves() raises:
    var index = SparseIndex()
    var elements: List[SparseElement] = [
        SparseElement(0, 16777216.0), SparseElement(1, 1.0),
        SparseElement(2, -16777216.0), SparseElement(3, 2.0),
    ]
    index.upsert(99, [SparseElement(7, 1.0)])
    index.upsert(4, elements)
    index.upsert(-4, elements)
    index.delete(99)
    var query: List[SparseElement] = [
        SparseElement(0, 1.0), SparseElement(1, 1.0),
        SparseElement(2, 1.0), SparseElement(3, 1.0),
    ]
    var results = index.search_dot(query, 2)
    assert_equal(results[0].id, -4)
    assert_equal(results[1].id, 4)
    assert_equal(results[0].score, 2.0)
    assert_equal(results[1].score, 2.0)
    var cloned = index.clone()
    assert_equal(cloned.search_dot(query, 2)[0].score, 2.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
