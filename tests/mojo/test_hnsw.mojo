from akasha.index.hnsw import HnswIndex, deterministic_level
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def test_level_generation_is_deterministic_and_bounded() raises:
    assert_equal(deterministic_level(8, 6), deterministic_level(8, 6))
    assert_true(deterministic_level(8, 6) >= 0)
    assert_true(deterministic_level(8, 6) <= 6)
    assert_true(deterministic_level(-8, 6) <= 6)


def test_graph_bounds_neighbors_and_rejects_duplicate_ids() raises:
    var index = HnswIndex(1, m=2, max_level=4)
    for id in range(12):
        index.add(id, [Float32(id)])

    assert_equal(index.point_count(), 12)
    assert_true(index.maximum_neighbor_count() <= 2)
    with assert_raises():
        index.add(3, [3.0])


def test_hnsw_search_finds_nearest_points_for_all_metrics() raises:
    var index = HnswIndex(2, m=4, max_level=6)
    for id in range(1, 41):
        index.add(id, [Float32(id), 0.0])

    var l2 = index.search_l2([19.2, 0.0], 3, 32)
    var dot = index.search_dot([1.0, 0.0], 2, 32)
    var cosine = index.search_cosine([1.0, 0.0], 2, 32)

    assert_equal(l2[0].id, 19)
    assert_equal(dot[0].id, 40)
    assert_equal(cosine[0].id, 1)
    assert_equal(cosine[1].id, 2)


def test_hnsw_validates_configuration_vectors_and_search() raises:
    with assert_raises():
        _ = HnswIndex(0)
    with assert_raises():
        _ = HnswIndex(2, m=0)

    var index = HnswIndex(2)
    with assert_raises():
        index.add(1, [1.0])
    index.add(1, [1.0, 0.0])
    with assert_raises():
        _ = index.search_l2([1.0], 1, 8)
    with assert_raises():
        _ = index.search_l2([1.0, 0.0], 0, 8)
    with assert_raises():
        _ = index.search_l2([1.0, 0.0], 1, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
