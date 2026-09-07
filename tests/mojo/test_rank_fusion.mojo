from akasha.index.flat import SearchResult
from akasha.query.fusion import reciprocal_rank_fusion
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def test_rrf_combines_dense_and_sparse_ranks() raises:
    var dense: List[SearchResult] = [
        SearchResult(1, 9.0),
        SearchResult(2, 8.0),
        SearchResult(3, 7.0),
    ]
    var sparse: List[SearchResult] = [
        SearchResult(3, 5.0),
        SearchResult(2, 4.0),
        SearchResult(4, 3.0),
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


def test_rrf_empty_one_sided_disjoint_and_signed_ids() raises:
    var empty = List[SearchResult]()
    assert_equal(len(reciprocal_rank_fusion(empty, empty, 1)), 0)
    var dense: List[SearchResult] = [SearchResult(-8, 10.0), SearchResult(Int.MIN, 0.0)]
    var one_sided = reciprocal_rank_fusion(empty, dense, 10, 1)
    assert_equal(len(one_sided), 2)
    assert_equal(one_sided[0].id, -8)
    assert_equal(one_sided[0].score, 0.5)
    var sparse: List[SearchResult] = [SearchResult(-9, -1.0), SearchResult(8, 0.0)]
    var disjoint = reciprocal_rank_fusion(dense, sparse, 10, 1)
    assert_equal(disjoint[0].id, -9)
    assert_equal(disjoint[1].id, -8)
    assert_equal(disjoint[2].id, Int.MIN)
    assert_equal(disjoint[3].id, 8)


def test_rrf_rehash_overlap_and_repeated_ids_match_ordered_sum() raises:
    var dense = List[SearchResult]()
    var sparse = List[SearchResult]()
    for index in range(128):
        dense.append(SearchResult(index - 64, 0.0))
        sparse.append(SearchResult(64 - index // 2, 0.0))
    for constant in [1, 60, 1024]:
        var fused = reciprocal_rank_fusion(dense, sparse, 200, constant)
        assert_equal(len(fused), 129)
        for hit_index in range(len(fused)):
            var hit = fused[hit_index]
            var expected = Float32(0.0)
            for index in range(len(dense)):
                if dense[index].id == hit.id:
                    expected += Float32(1.0 / Float64(constant + index + 1))
            for index in range(len(sparse)):
                if sparse[index].id == hit.id:
                    expected += Float32(1.0 / Float64(constant + index + 1))
            assert_equal(hit.score, expected)
            if hit_index > 0:
                var previous = fused[hit_index - 1]
                assert_true(previous.score > hit.score or (previous.score == hit.score and previous.id < hit.id))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
