from akasha.index.flat import SearchResult
from akasha.query.fusion import reciprocal_rank_fusion
from std.testing import assert_equal, assert_raises, TestSuite


def test_rrf_combines_dense_and_sparse_ranks() raises:
    var dense: List[SearchResult] = [
        SearchResult(1, 9.0), SearchResult(2, 8.0), SearchResult(3, 7.0)
    ]
    var sparse: List[SearchResult] = [
        SearchResult(3, 5.0), SearchResult(2, 4.0), SearchResult(4, 3.0)
    ]

    var fused = reciprocal_rank_fusion(dense, sparse, 4, 60)

    assert_equal(fused[0].id, 3)
    assert_equal(fused[1].id, 2)
    assert_equal(fused[2].id, 1)
    assert_equal(fused[3].id, 4)


def test_rrf_ties_use_ascending_point_id() raises:
    var dense: List[SearchResult] = [SearchResult(2, 1.0)]
    var sparse: List[SearchResult] = [SearchResult(1, 1.0)]
    var fused = reciprocal_rank_fusion(dense, sparse, 2, 60)
    assert_equal(fused[0].id, 1)
    assert_equal(fused[1].id, 2)


def test_rrf_validates_parameters() raises:
    var empty = List[SearchResult]()
    with assert_raises():
        _ = reciprocal_rank_fusion(empty, empty, 0, 60)
    with assert_raises():
        _ = reciprocal_rank_fusion(empty, empty, 1, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
