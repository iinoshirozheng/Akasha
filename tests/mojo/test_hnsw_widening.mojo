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


def _chain_index() raises -> HnswIndex:
    var config = CollectionConfig.defaults(1)
    config.ann_metric = MetricKind.l2()
    config.m = 2
    config.m0 = 2
    config.default_ef_search = 2
    config.max_ef_search = 4_294_967_295
    var index = HnswIndex(config)
    for ordinal in range(4):
        var values = _vector(Float32(ordinal))
        var slot = index.graph.append(10 + ordinal, values^, 0)
        if ordinal == 0:
            index.entry_slot = Optional(slot)
            index.entry_level = 0
    var n0: List[UInt32] = [UInt32(1)]
    var n1: List[UInt32] = [UInt32(0), UInt32(2)]
    var n2: List[UInt32] = [UInt32(1), UInt32(3)]
    var n3: List[UInt32] = [UInt32(2)]
    index.graph.set_neighbors(UInt32(0), 0, n0^)
    index.graph.set_neighbors(UInt32(1), 0, n1^)
    index.graph.set_neighbors(UInt32(2), 0, n2^)
    index.graph.set_neighbors(UInt32(3), 0, n3^)
    index.build_stats.slot_count = 4
    index.build_stats.maximum_level = 0
    return index^


def _allow_tail_two() raises -> HnswEligibility:
    var ordinals = Dict[Int, Int]()
    for ordinal in range(4):
        ordinals[10 + ordinal] = ordinal
    var lookup = HnswIdOrdinalLookup(ordinals^, 4)
    var bitmap = Bitmap(4)
    bitmap.set(2)
    bitmap.set(3)
    return HnswEligibility(bitmap^, lookup)


def _assert_unique_ids(results: List[SearchResult]) raises:
    var seen = Dict[Int, Bool]()
    for result in results:
        assert_equal(result.id in seen, False)
        seen[result.id] = True


def test_filtered_search_widens_by_doubling_and_reruns_with_scratch() raises:
    var index = _chain_index()
    var allowed = _allow_tail_two()
    var query = _vector(0.0)
    var starting_epoch = index.scratch.epoch
    var results = index.search_allowed_with_widening(
        query, 2, 2, 4, 2, allowed
    )

    assert_equal(len(results), 2)
    assert_equal(results[0].id, 12)
    assert_equal(results[1].id, 13)
    _assert_unique_ids(results)
    assert_equal(index.scratch.epoch, starting_epoch + UInt32(2))
    assert_equal(index.last_search_stats.requested_ef, 4)
    assert_equal(index.last_search_stats.effective_ef, 4)
    assert_equal(index.last_search_stats.widening_rounds, 1)
    assert_equal(index.last_search_stats.fallback_reason, "")
    assert_equal(index.scratch.filtered_result_reserved_capacity() >= 4, True)


def test_filtered_search_exact_fallback_preserves_final_ann_stats() raises:
    var index = _chain_index()
    var allowed = _allow_tail_two()
    var query = _vector(0.0)
    var results = index.search_allowed_with_widening(
        query, 2, 2, 2, 2, allowed
    )

    assert_equal(len(results), 2)
    assert_equal(results[0].id, 12)
    assert_equal(results[1].id, 13)
    _assert_unique_ids(results)
    assert_equal(index.last_search_stats.requested_ef, 2)
    assert_equal(index.last_search_stats.effective_ef, 2)
    assert_equal(index.last_search_stats.widening_rounds, 0)
    assert_equal(index.last_search_stats.base_visited, 3)
    assert_equal(index.last_search_stats.distance_evaluations, 3)
    assert_equal(
        index.last_search_stats.fallback_reason,
        "filtered_ann_exhausted",
    )


def test_matched_count_below_k_does_not_widen_after_target_is_filled() raises:
    var index = _chain_index()
    var ordinals = Dict[Int, Int]()
    for ordinal in range(4):
        ordinals[10 + ordinal] = ordinal
    var lookup = HnswIdOrdinalLookup(ordinals^, 4)
    var bitmap = Bitmap(4)
    bitmap.set(2)
    var allowed = HnswEligibility(bitmap^, lookup)
    var query = _vector(0.0)
    var starting_epoch = index.scratch.epoch
    var results = index.search_allowed_with_widening(
        query, 2, 2, 4, 1, allowed
    )

    assert_equal(len(results), 1)
    assert_equal(results[0].id, 12)
    assert_equal(index.scratch.epoch, starting_epoch + UInt32(1))
    assert_equal(index.last_search_stats.widening_rounds, 0)
    assert_equal(index.last_search_stats.fallback_reason, "")


def test_next_widened_ef_saturates_without_overflow() raises:
    assert_equal(HnswIndex.next_widened_ef(2, 9), 4)
    assert_equal(HnswIndex.next_widened_ef(8, 9), 9)
    assert_equal(
        HnswIndex.next_widened_ef(2_147_483_648, 4_294_967_295),
        4_294_967_295,
    )
    assert_equal(
        HnswIndex.next_widened_ef(4_294_967_295, 4_294_967_295),
        4_294_967_295,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
