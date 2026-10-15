from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.bitmap import Bitmap
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup
from akasha.index.segmented_hnsw import SegmentedHnsw, _FilteredSourceAdmission
from akasha.storage.filesystem import remove_file_if_exists, write_file_sync
from akasha.storage.hnsw_store import encode_hnsw_snapshot, open_hnsw_snapshot_view
from akasha.storage.memtable import MemTable
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_false, assert_true, assert_raises, TestSuite


def _config() -> CollectionConfig:
    var config = CollectionConfig.defaults(1)
    config.ann_metric = MetricKind.l2()
    config.m = 4
    config.m0 = 8
    config.ef_construction = 24
    config.default_ef_search = 16
    config.max_ef_search = 256
    return config^


def _allowed(lookup: HnswIdOrdinalLookup, ordinal: Int) raises -> HnswEligibility:
    var bits = Bitmap(lookup.entry_count())
    bits.set(ordinal)
    return HnswEligibility(bits^, lookup)


def _exercise_projection(mapped: Bool) raises:
    var config = _config()
    var table = MemTable(1)
    var base = HnswIndex(config.copy())
    var ids = [-11, 0, 99, 42]
    for ordinal in range(len(ids)):
        var vector: List[Float32] = [Float32(ordinal)]
        table.apply_upsert(ids[ordinal], UInt64(ordinal + 1), vector.copy())
        base.add(ids[ordinal], vector^)
    base.upsert(99, [2.0])
    assert_true(base.delete(42))
    table.apply_delete(42, 10)
    var path = String("/tmp/akasha-base-ordinals-", Int(external_call["getpid", c_int]()))
    var index: SegmentedHnsw
    if mapped:
        remove_file_if_exists(path)
        write_file_sync(path, encode_hnsw_snapshot(base, 10))
        var view = open_hnsw_snapshot_view(path, config, 10)
        index = SegmentedHnsw.from_mapped(view^)
    else:
        index = SegmentedHnsw.from_owned(base^)
    var table_lookup = HnswIdOrdinalLookup({-11: 0, 0: 1, 99: 2, 42: 3}, 4)
    # Missing IDs are excluded until appended to the same lookup owner.
    var lookup = HnswIdOrdinalLookup({-11: 0}, 1)
    var first = index.search_allowed([0.0], 1, 16, 16, _allowed(lookup, 0), table, table_lookup)
    assert_equal(first[0].id, -11)
    var projection = index._sources._state[].base_ordinals.value()
    var repeat = index.search_allowed([0.0], 1, 16, 16, _allowed(lookup, 0), table, table_lookup)
    assert_equal(repeat[0].id, -11)
    assert_true(projection is index._sources._state[].base_ordinals.value())
    lookup.append(0, 1)
    var second = index.search_allowed([1.0], 1, 16, 16, _allowed(lookup, 1), table, table_lookup)
    assert_equal(second[0].id, 0)
    assert_true(projection is index._sources._state[].base_ordinals.value())
    lookup.append(99, 2)
    var third = index.search_allowed([2.0], 1, 16, 16, _allowed(lookup, 2), table, table_lookup)
    assert_equal(third[0].id, 99)
    assert_equal(third[0].score, Float32(0))
    assert_true(projection is index._sources._state[].base_ordinals.value())
    assert_equal(len(projection[].missing_slots), 1)

    # A different owner can reorder ordinals without changing cardinality.
    var reordered = HnswIdOrdinalLookup({-11: 2, 0: 0, 99: 1}, 3)
    var allowed = _allowed(reordered, 0)
    var result = index.search_allowed([1.0], 1, 16, 16, allowed, table, table_lookup)
    assert_equal(result[0].id, 0)
    assert_false(projection is index._sources._state[].base_ordinals.value())
    var invalid = _FilteredSourceAdmission(index._sources, False, allowed, projection)
    with assert_raises(contains="projection is stale"):
        invalid.validate(index.base_slot_count())

    # Source replacement still rejects the cached base slot; delta uses its ID.
    var current_projection = index._sources._state[].base_ordinals.value()
    table.apply_upsert(0, 11, [50.0])
    index.upsert(0, [50.0])
    var updated = index.search_allowed([50.0], 1, 16, 16, allowed, table, table_lookup)
    assert_equal(updated[0].id, 0)
    assert_equal(updated[0].score, Float32(0))
    assert_true(current_projection is index._sources._state[].base_ordinals.value())
    index.validate_structure()
    index.close()
    if mapped:
        remove_file_if_exists(path)


def test_owned_projection_reuses_owner_and_tracks_lookup_changes() raises:
    _exercise_projection(False)


def test_mapped_projection_reuses_owner_and_tracks_lookup_changes() raises:
    _exercise_projection(True)


def test_delta_promotion_creates_a_projection_for_the_new_base() raises:
    var index = SegmentedHnsw(_config())
    var table = MemTable(1)
    index.upsert(-7, [3.0])
    table.apply_upsert(-7, 1, [3.0])
    var lookup = HnswIdOrdinalLookup({-7: 0}, 1)
    var allowed = _allowed(lookup, 0)
    var delta = index.search_allowed([3.0], 1, 16, 16, allowed, table, lookup)
    assert_equal(delta[0].id, -7)
    assert_false(Bool(index._sources._state[].base_ordinals))
    index.promote_delta_base()
    var base = index.search_allowed([3.0], 1, 16, 16, allowed, table, lookup)
    assert_equal(base[0].id, -7)
    assert_equal(base[0].score, delta[0].score)
    assert_true(Bool(index._sources._state[].base_ordinals))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
