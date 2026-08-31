from akasha import CollectionConfig, MetricKind, PersistentCollection
from akasha.index.hnsw import HnswIndex
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    TestSuite,
)


def _reset(directory: String) raises:
    ensure_directory(directory)
    var names = [
        "collection.bin",
        "collection.bin.tmp",
        "wal.bin",
        "wal.bin.tmp",
        "sparse.wal",
        "sparse.wal.tmp",
        "manifest.bin",
        "manifest.bin.tmp",
        "hnsw.cache",
        "hnsw.cache.tmp",
        "metadata.cache",
        "metadata.cache.tmp",
        "collection.lock",
    ]
    for name in names:
        remove_file_if_exists(directory + "/" + name)
    for sequence in range(256):
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-delta-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-delta-" + String(sequence) + ".bin"
        )


def _config(
    *, inactive_percent: Int = 25, delta_max_points: Int = 10_000
) -> CollectionConfig:
    var config = CollectionConfig.defaults(1)
    config.ann_metric = MetricKind.l2()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 1_024
    config.max_level = 4
    config.level_seed = UInt64(0x19A5A19A5)
    config.rebuild_inactive_percent = inactive_percent
    config.delta_max_points = delta_max_points
    return config^


def _assert_same_graph(left: HnswIndex, right: HnswIndex) raises:
    assert_equal(left.point_count(), right.point_count())
    assert_equal(left.entry_slot.value(), right.entry_slot.value())
    assert_equal(left.entry_point_level(), right.entry_point_level())
    for slot_index in range(left.point_count()):
        var slot = UInt32(slot_index)
        assert_equal(left.graph.id_at(slot), right.graph.id_at(slot))
        assert_equal(left.graph.level(slot), right.graph.level(slot))
        for component in range(left.dimension):
            assert_equal(
                left.graph.vector_value(slot, component),
                right.graph.vector_value(slot, component),
            )
        for level in range(left.graph.level(slot) + 1):
            var count = left.graph.neighbor_count(slot, level)
            assert_equal(count, right.graph.neighbor_count(slot, level))
            for edge in range(count):
                assert_equal(
                    left.graph.neighbor_at(slot, level, edge),
                    right.graph.neighbor_at(slot, level, edge),
                )


def test_inactive_threshold_rebuilds_at_boundary() raises:
    var index = HnswIndex(_config(inactive_percent=25))
    for id in range(4):
        index.upsert(id, [Float32(id)])
    assert_false(index.needs_rebuild())
    assert_true(index.delete(0))
    assert_true(index.needs_rebuild())


def test_explicit_rebuild_is_deterministic_and_removes_inactive_slots() raises:
    var first_path = String("/tmp/akasha-task19-deterministic-first")
    var second_path = String("/tmp/akasha-task19-deterministic-second")
    _reset(first_path)
    _reset(second_path)
    var config = _config(inactive_percent=20)
    var first = PersistentCollection.open_with_config(first_path, config.copy())
    var second = PersistentCollection.open_with_config(
        second_path, config.copy()
    )
    for id in range(32):
        first.upsert(id, [Float32((id * 17) % 31)])
        second.upsert(id, [Float32((id * 17) % 31)])
    first.upsert(7, [-7.0])
    second.upsert(7, [-7.0])
    first.delete(8)
    second.delete(8)

    first.rebuild_hnsw()
    second.rebuild_hnsw()

    assert_true(first.hnsw_available())
    assert_true(second.hnsw_available())
    assert_equal(first.hnsw_inactive_count(), 0)
    assert_equal(second.hnsw_inactive_count(), 0)
    assert_equal(first.hnsw_slot_count(), 31)
    assert_equal(second.hnsw_slot_count(), 31)
    assert_equal(first._hnsw.checkpoint_base().graph.id_at(UInt32(0)), 0)
    assert_equal(first._hnsw.checkpoint_base().graph.id_at(UInt32(7)), 9)
    assert_equal(first._hnsw.checkpoint_base().graph.id_at(UInt32(30)), 7)
    first._hnsw.validate_structure()
    second._hnsw.validate_structure()
    _assert_same_graph(
        first._hnsw.checkpoint_base(), second._hnsw.checkpoint_base()
    )


def test_live_results_are_equivalent_across_rebuild() raises:
    var path = String("/tmp/akasha-task19-live-equivalence")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    collection.upsert(79, [-1.0])
    collection.delete(78)
    var before = collection.search_l2_approx([77.0], 79, 128)

    collection.rebuild_hnsw()
    var after = collection.search_l2_approx([77.0], 79, 128)

    assert_equal(len(before), len(after))
    for index in range(len(before)):
        assert_equal(before[index].id, after[index].id)


def test_explicit_rebuild_recovers_an_unavailable_invalid_graph() raises:
    var path = String("/tmp/akasha-task19-invalid-recovery")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    collection._hnsw._delta.config.dimension = 2
    collection.upsert(999, [999.0])
    assert_false(collection.hnsw_available())

    collection.rebuild_hnsw()

    assert_true(collection.hnsw_available())
    assert_equal(collection.hnsw_unavailable_reason(), "")
    assert_equal(collection.hnsw_inactive_count(), 0)
    assert_equal(collection.hnsw_slot_count(), 81)
    collection._hnsw.validate_structure()
    assert_equal(collection.search_l2_approx([999.0], 1, 64)[0].id, 999)


def test_rebuild_failure_preserves_authoritative_data_and_quarantines_graph() raises:
    var path = String("/tmp/akasha-task19-rebuild-failure")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    collection.upsert(1, [42.0])
    var original_m = collection._config.m
    collection._config.m = 0

    var failed = False
    try:
        collection.rebuild_hnsw()
    except:
        failed = True

    assert_true(failed)
    assert_false(collection.hnsw_available())
    assert_equal(collection.hnsw_unavailable_reason(), "rebuild_failed")
    assert_equal(collection.get(1).value().vector[0], Float32(42.0))

    collection._config.m = original_m
    collection.rebuild_hnsw()
    assert_true(collection.hnsw_available())
    assert_equal(collection.get(1).value().vector[0], Float32(42.0))


def test_flush_materializes_a_complete_base_below_delta_threshold() raises:
    var path = String("/tmp/akasha-task19-delta-threshold")
    _reset(path)
    var collection = PersistentCollection.open_with_config(
        path, _config(inactive_percent=90, delta_max_points=3)
    )
    collection.upsert(1, [1.0])
    collection.upsert(2, [2.0])
    assert_equal(collection._hnsw_mutations_since_rebuild, 2)
    collection.flush()
    assert_equal(collection._hnsw_mutations_since_rebuild, 0)
    assert_true(collection._hnsw.checkpoint_ready())

    collection.upsert(3, [3.0])
    assert_equal(collection._hnsw_mutations_since_rebuild, 1)
    collection.upsert(4, [4.0])
    assert_equal(collection._hnsw_mutations_since_rebuild, 2)
    collection.flush()
    assert_equal(collection._hnsw_mutations_since_rebuild, 0)
    assert_equal(collection.hnsw_inactive_count(), 0)
    assert_equal(collection.hnsw_slot_count(), 4)


def test_frozen_base_replacements_stay_in_delta_until_flush() raises:
    var path = String("/tmp/akasha-task19-inactive-flush-threshold")
    _reset(path)
    var collection = PersistentCollection.open_with_config(
        path, _config(inactive_percent=25, delta_max_points=10_000)
    )
    for id in range(4):
        collection.upsert(id, [Float32(id)])
    collection.rebuild_hnsw()
    collection.upsert(0, [10.0])
    assert_false(collection._hnsw.needs_rebuild())
    assert_equal(collection._hnsw.base_slot_count(), 4)
    assert_equal(collection._hnsw.delta_slot_count(), 1)
    assert_equal(collection.hnsw_inactive_count(), 0)
    collection.flush()
    assert_equal(collection.hnsw_inactive_count(), 0)
    assert_true(collection._hnsw.checkpoint_ready())

    collection.upsert(1, [11.0])
    assert_false(collection._hnsw.needs_rebuild())
    collection.flush()
    assert_equal(collection.hnsw_inactive_count(), 0)
    assert_equal(collection._hnsw_mutations_since_rebuild, 0)


def test_empty_collection_explicit_rebuild_and_flush_stay_available() raises:
    var path = String("/tmp/akasha-task19-empty-rebuild")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())

    collection.rebuild_hnsw()
    collection.flush()

    assert_true(collection.hnsw_available())
    assert_equal(collection.hnsw_slot_count(), 0)
    assert_equal(collection.hnsw_inactive_count(), 0)
    assert_equal(len(collection.search_l2_approx([0.0], 1, 8)), 0)


def test_all_tombstoned_rebuild_and_flush_remove_stale_graph_state() raises:
    var path = String("/tmp/akasha-task19-all-tombstoned-rebuild")
    _reset(path)
    var collection = PersistentCollection.open_with_config(path, _config())
    for id in range(8):
        collection.upsert(id, [Float32(id)])
    for id in range(8):
        collection.delete(id)
    assert_true(collection._hnsw.needs_rebuild())

    collection.rebuild_hnsw()
    collection.flush()

    assert_true(collection.hnsw_available())
    assert_equal(collection.hnsw_slot_count(), 0)
    assert_equal(collection.hnsw_inactive_count(), 0)
    assert_equal(len(collection.search_l2_approx([0.0], 1, 8)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
