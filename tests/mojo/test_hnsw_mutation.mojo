from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.hnsw import HnswIndex
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _config(*, rebuild_percent: Int = 25) -> CollectionConfig:
    var config = CollectionConfig.defaults(2)
    config.ann_metric = MetricKind.l2()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 1_024
    config.max_level = 1
    config.level_seed = UInt64(0x17A5A17A5)
    config.rebuild_inactive_percent = rebuild_percent
    return config^


def _vector(x: Float32, y: Float32) -> List[Float32]:
    var values: List[Float32] = [x, y]
    return values^


def _mixed_vector(step: Int, id: Int) -> List[Float32]:
    return _vector(
        Float32((step * 17 + id * 7) % 101) * 0.01,
        Float32((step * 29 + id * 11) % 103) * 0.01,
    )


def test_upsert_inserts_and_replaces_with_a_new_current_slot() raises:
    var index = HnswIndex(_config())
    index.upsert(7, _vector(0.0, 0.0))
    assert_equal(index.point_count(), 1)
    assert_equal(index.inactive_count(), 0)
    assert_equal(index.graph.current_slot(7).value(), UInt32(0))

    index.upsert(7, _vector(9.0, 9.0))
    assert_equal(index.point_count(), 2)
    assert_equal(index.inactive_count(), 1)
    assert_true(index.graph.is_replaced(UInt32(0)))
    assert_equal(index.graph.current_slot(7).value(), UInt32(1))
    var results = index.search(_vector(9.0, 9.0), 1, ef_search=8)
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 7)
    index.validate_structure()


def test_upsert_prepares_before_retiring_the_current_slot() raises:
    var index = HnswIndex(_config())
    index.upsert(11, _vector(1.0, 2.0))
    with assert_raises():
        index.upsert(11, [Float32(3.0)])

    assert_equal(index.point_count(), 1)
    assert_equal(index.inactive_count(), 0)
    assert_equal(index.graph.current_slot(11).value(), UInt32(0))
    assert_equal(index.search(_vector(1.0, 2.0), 1)[0].id, 11)
    index.validate_structure()


def test_delete_is_idempotent_and_delete_reinsert_revives_id() raises:
    var index = HnswIndex(_config())
    index.upsert(3, _vector(3.0, 0.0))
    assert_true(index.delete(3))
    assert_false(index.delete(3))
    assert_equal(index.inactive_count(), 1)
    assert_equal(len(index.search(_vector(3.0, 0.0), 1)), 0)
    assert_true(index.needs_rebuild())

    index.upsert(3, _vector(0.0, 3.0))
    assert_equal(index.graph.current_slot(3).value(), UInt32(1))
    assert_equal(index.search(_vector(0.0, 3.0), 1)[0].id, 3)
    index.validate_structure()


def test_inactive_old_slot_is_traversal_bridge_but_never_result() raises:
    var index = HnswIndex(_config())
    index.upsert(50, _vector(3.0, 0.0))
    index.upsert(20, _vector(2.0, 0.0))
    index.upsert(11, _vector(0.0, 0.0))
    assert_true(index.delete(20))

    var root: List[UInt32] = [UInt32(1)]
    var bridge: List[UInt32] = [UInt32(0), UInt32(2)]
    var target: List[UInt32] = [UInt32(1)]
    index.graph.set_neighbors(UInt32(0), 0, root^)
    index.graph.set_neighbors(UInt32(1), 0, bridge^)
    index.graph.set_neighbors(UInt32(2), 0, target^)
    index.entry_slot = Optional(UInt32(0))
    index.entry_level = 0

    var results = index.search(_vector(0.0, 0.0), 3, ef_search=8)
    assert_equal(len(results), 2)
    assert_equal(results[0].id, 11)
    assert_equal(results[1].id, 50)
    assert_true(index.last_search_stats.inactive_rejections > 0)
    index.validate_structure()


def test_replacing_entry_moves_entry_and_map_to_newest_slot() raises:
    var index = HnswIndex(_config())
    index.upsert(99, _vector(1.0, 1.0))
    var old_entry = index.entry_slot.value()
    index.upsert(99, _vector(2.0, 2.0))

    var newest = index.graph.current_slot(99).value()
    assert_equal(old_entry, UInt32(0))
    assert_equal(newest, UInt32(1))
    assert_equal(index.entry_slot.value(), newest)
    assert_false(index.graph.is_current(old_entry))
    assert_true(index.graph.is_current(newest))
    index.validate_structure()


def test_inactive_ratio_uses_configured_threshold() raises:
    var index = HnswIndex(_config(rebuild_percent=50))
    for id in range(4):
        index.upsert(id, _vector(Float32(id), 0.0))
    assert_false(index.needs_rebuild())
    assert_true(index.delete(0))
    assert_false(index.needs_rebuild())
    assert_true(index.delete(1))
    assert_true(index.needs_rebuild())
    assert_equal(index.inactive_count(), 2)
    index.validate_structure()


def test_empty_live_graph_returns_empty_with_inactive_entry() raises:
    var index = HnswIndex(_config())
    for id in range(4):
        index.upsert(id, _vector(Float32(id), 0.0))
    for id in range(4):
        assert_true(index.delete(id))

    assert_true(Bool(index.entry_slot))
    assert_false(index.graph.is_current(index.entry_slot.value()))
    assert_equal(len(index.search(_vector(0.0, 0.0), 4)), 0)
    index.validate_structure()


def test_legacy_cache_rejects_mutation_history() raises:
    var index = HnswIndex(2, m=4, max_level=0)
    index.upsert(1, _vector(1.0, 1.0))
    index.upsert(1, _vector(2.0, 2.0))
    with assert_raises():
        _ = index.encode_cache_payload()


def test_invalid_graph_always_needs_rebuild() raises:
    var index = HnswIndex(_config(rebuild_percent=90))
    index.upsert(1, _vector(1.0, 1.0))
    index.graph.mark_invalid()
    assert_true(index.needs_rebuild())


def test_delete_quarantines_diverged_identity_before_tombstoning() raises:
    var index = HnswIndex(_config())
    index.upsert(1, _vector(1.0, 1.0))
    index.dimension = 3

    assert_false(index.delete(1))
    assert_true(index.graph.is_current(UInt32(0)))
    assert_false(index.valid)
    assert_true(index.needs_rebuild())


def test_graph_stays_valid_after_500_deterministic_mixed_operations() raises:
    var index = HnswIndex(_config(rebuild_percent=90))
    for step in range(500):
        var id = (step * 37 + 11) % 64
        if step % 10 < 2:
            index.upsert(id, _mixed_vector(step, id))
        else:
            _ = index.delete(id)

    index.validate_structure()

    assert_equal(index.build_slot_count(), index.point_count())
    assert_equal(index.build_stats.inactive_slots, index.inactive_count())
    assert_true(index.graph.is_valid())
    assert_true(index.valid)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
