from akasha.index.sparse import SparseElement, SparseIndex
from std.testing import assert_almost_equal, assert_equal, assert_raises, TestSuite


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
