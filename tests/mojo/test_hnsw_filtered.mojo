from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.bitmap import Bitmap
from akasha.index.flat import SearchResult
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup
from std.collections import Dict
from std.testing import assert_equal, TestSuite


def _vector(value: Float32) -> List[Float32]:
    var values: List[Float32] = [value]
    return values^


def _index(ids: List[Int], values: List[Float32]) raises -> HnswIndex:
    var config = CollectionConfig.defaults(1)
    config.ann_metric = MetricKind.l2()
    config.m = 4
    config.m0 = 4
    config.default_ef_search = 8
    config.max_ef_search = 32
    var index = HnswIndex(config)
    for ordinal in range(len(ids)):
        var vector = _vector(values[ordinal])
        var slot = index.graph.append(ids[ordinal], vector^, 0)
        if ordinal == 0:
            index.entry_slot = Optional(slot)
            index.entry_level = 0
    index.build_stats.slot_count = len(ids)
    index.build_stats.maximum_level = 0 if len(ids) > 0 else -1
    return index^


def _set_neighbors(
    mut index: HnswIndex, slot: Int, neighbors: List[UInt32]
) raises:
    index.graph.set_neighbors(UInt32(slot), 0, neighbors)


def _ordinal_map(ids_by_ordinal: List[Int]) -> Dict[Int, Int]:
    var result = Dict[Int, Int]()
    for ordinal in range(len(ids_by_ordinal)):
        result[ids_by_ordinal[ordinal]] = ordinal
    return result^


def _assert_same_results(
    left: List[SearchResult],
    right: List[SearchResult],
) raises:
    assert_equal(len(left), len(right))
    for index in range(len(left)):
        assert_equal(left[index].id, right[index].id)
        assert_equal(left[index].score, right[index].score)


def test_allow_all_matches_unfiltered_search() raises:
    var ids: List[Int] = [90, 10, 70, 30]
    var values: List[Float32] = [9.0, 1.0, 7.0, 3.0]
    var index = _index(ids, values)
    var n0: List[UInt32] = [UInt32(1), UInt32(2), UInt32(3)]
    var n1: List[UInt32] = [UInt32(0), UInt32(2), UInt32(3)]
    var n2: List[UInt32] = [UInt32(0), UInt32(1), UInt32(3)]
    var n3: List[UInt32] = [UInt32(0), UInt32(1), UInt32(2)]
    _set_neighbors(index, 0, n0^)
    _set_neighbors(index, 1, n1^)
    _set_neighbors(index, 2, n2^)
    _set_neighbors(index, 3, n3^)
    var query = _vector(0.0)
    var expected = index.search(query, 3, ef_search=4)
    var ordinals = _ordinal_map(ids)
    var lookup = HnswIdOrdinalLookup(ordinals^)
    var full = Bitmap.full(4)
    var allow_all = HnswEligibility(full^, lookup)
    var actual = index.search_allowed(query, 3, 4, allow_all)
    _assert_same_results(expected, actual)
    assert_equal(index.last_search_stats.filtered_rejections, 0)


def test_empty_full_and_sparse_metadata_bitmaps() raises:
    var ids: List[Int] = [900, 100, 700]
    var values: List[Float32] = [9.0, 1.0, 7.0]
    var index = _index(ids, values)
    var n0: List[UInt32] = [UInt32(1), UInt32(2)]
    var n1: List[UInt32] = [UInt32(0), UInt32(2)]
    var n2: List[UInt32] = [UInt32(0), UInt32(1)]
    _set_neighbors(index, 0, n0^)
    _set_neighbors(index, 1, n1^)
    _set_neighbors(index, 2, n2^)
    # Metadata order intentionally differs from graph slot order.
    var metadata_ids: List[Int] = [100, 700, 900]
    var ordinals = _ordinal_map(metadata_ids)
    var lookup = HnswIdOrdinalLookup(ordinals^)
    var query = _vector(0.0)

    var empty = Bitmap(3)
    var empty_allowed = HnswEligibility(empty^, lookup)
    var empty_results = index.search_allowed(query, 3, 3, empty_allowed)
    assert_equal(len(empty_results), 0)
    assert_equal(index.last_search_stats.filtered_rejections, 3)

    var full = Bitmap.full(3)
    var full_allowed = HnswEligibility(full^, lookup)
    var full_results = index.search_allowed(query, 3, 3, full_allowed)
    assert_equal(len(full_results), 3)
    assert_equal(full_results[0].id, 100)
    assert_equal(full_results[1].id, 700)
    assert_equal(full_results[2].id, 900)
    assert_equal(index.last_search_stats.filtered_rejections, 0)

    var sparse = Bitmap(3)
    sparse.set(1)
    var sparse_allowed = HnswEligibility(sparse^, lookup)
    var sparse_results = index.search_allowed(query, 3, 3, sparse_allowed)
    assert_equal(len(sparse_results), 1)
    assert_equal(sparse_results[0].id, 700)
    assert_equal(index.last_search_stats.filtered_rejections, 2)


def test_disallowed_bridge_remains_traversable_to_allowed_result() raises:
    var ids: List[Int] = [30, 20, 10]
    var values: List[Float32] = [3.0, 2.0, 0.0]
    var index = _index(ids, values)
    var root: List[UInt32] = [UInt32(1)]
    var bridge: List[UInt32] = [UInt32(0), UInt32(2)]
    var target: List[UInt32] = [UInt32(1)]
    _set_neighbors(index, 0, root^)
    _set_neighbors(index, 1, bridge^)
    _set_neighbors(index, 2, target^)

    var metadata_ids: List[Int] = [10, 20, 30]
    var ordinals = _ordinal_map(metadata_ids)
    var lookup = HnswIdOrdinalLookup(ordinals^)
    var bitmap = Bitmap(3)
    bitmap.set(0)
    var allowed = HnswEligibility(bitmap^, lookup)
    var query = _vector(0.0)
    var results = index.search_allowed(query, 1, 3, allowed)

    assert_equal(len(results), 1)
    assert_equal(results[0].id, 10)
    assert_equal(index.last_search_stats.base_visited, 3)
    assert_equal(index.last_search_stats.filtered_rejections, 2)


def test_allowed_ids_fewer_than_k_returns_only_allowed_ids() raises:
    var ids: List[Int] = [40, 30, 20, 10]
    var values: List[Float32] = [4.0, 3.0, 2.0, 1.0]
    var index = _index(ids, values)
    var n0: List[UInt32] = [UInt32(1), UInt32(2), UInt32(3)]
    var n1: List[UInt32] = [UInt32(0), UInt32(2), UInt32(3)]
    var n2: List[UInt32] = [UInt32(0), UInt32(1), UInt32(3)]
    var n3: List[UInt32] = [UInt32(0), UInt32(1), UInt32(2)]
    _set_neighbors(index, 0, n0^)
    _set_neighbors(index, 1, n1^)
    _set_neighbors(index, 2, n2^)
    _set_neighbors(index, 3, n3^)
    var metadata_ids: List[Int] = [10, 20, 30, 40]
    var ordinals = _ordinal_map(metadata_ids)
    var lookup = HnswIdOrdinalLookup(ordinals^)
    var bitmap = Bitmap(4)
    bitmap.set(1)
    var allowed = HnswEligibility(bitmap^, lookup)
    assert_equal(allowed.allows(20), True)
    assert_equal(allowed.allows(10), False)
    var query = _vector(0.0)
    var results = index.search_allowed(query, 3, 4, allowed)

    assert_equal(len(results), 1)
    assert_equal(results[0].id, 20)
    assert_equal(index.last_search_stats.filtered_rejections, 3)


def test_repeated_filtered_queries_share_lookup_without_setup_scan() raises:
    var ids: List[Int] = [20, 10]
    var values: List[Float32] = [2.0, 1.0]
    var index = _index(ids, values)
    var left: List[UInt32] = [UInt32(1)]
    var right: List[UInt32] = [UInt32(0)]
    _set_neighbors(index, 0, left^)
    _set_neighbors(index, 1, right^)

    var ordinals = Dict[Int, Int]()
    for ordinal in range(2_048):
        ordinals[10_000 + ordinal] = ordinal
    ordinals[20] = 17
    ordinals[10] = 1_999
    var lookup = HnswIdOrdinalLookup(ordinals^)
    assert_equal(lookup.entry_count(), 2_050)
    assert_equal(lookup.setup_scanned_entries(), 0)

    var first_bitmap = Bitmap(2_048)
    first_bitmap.set(17)
    var first_allowed = HnswEligibility(first_bitmap^, lookup)
    var query = _vector(0.0)
    var first = index.search_allowed(query, 1, 2, first_allowed)
    assert_equal(len(first), 1)
    assert_equal(first[0].id, 20)

    var second_bitmap = Bitmap(2_048)
    second_bitmap.set(1_999)
    var second_allowed = HnswEligibility(second_bitmap^, lookup)
    var second = index.search_allowed(query, 1, 2, second_allowed)
    assert_equal(len(second), 1)
    assert_equal(second[0].id, 10)
    assert_equal(lookup.setup_scanned_entries(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
