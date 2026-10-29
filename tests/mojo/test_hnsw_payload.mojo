from akasha.index.hnsw_query_scorer import MetricPointScorer
from akasha.index.hnsw_entries import HnswEntry
from akasha.common.config import CollectionConfig
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup, HnswSearchAdmission
from akasha.index.hnsw_payload import attach_payload_graphs, payload_blocks
from akasha.index.hnsw_search import search
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.metadata import MetadataIndex
from akasha.index.bitmap import Bitmap
from akasha.storage.hnsw_store import encode_hnsw_snapshot, decode_hnsw_snapshot_owned, open_hnsw_snapshot_view
from akasha.storage.filesystem import ensure_directory, write_file_sync
from std.testing import assert_equal, assert_true, TestSuite


def test_numeric_blocks_overlap_and_keep_equal_values_together() raises:
    var metadata = MetadataIndex()
    metadata.begin_bulk()
    for id in range(12):
        metadata.upsert(id, [DocumentField("group", PayloadValue.integer(Int64(id // 2)))])
    metadata.finish_bulk()
    var blocks = payload_blocks(metadata, 4, 6)
    assert_equal(len(blocks), 5)
    assert_equal(blocks[0].ids, [0, 1, 2, 3])
    assert_equal(blocks[1].ids, [2, 3, 4, 5])
    assert_equal(blocks[4].ids, [8, 9, 10, 11])
    assert_equal(len(payload_blocks(metadata, 4, 3)), 0)


def test_payload_graph_recovers_filtered_connectivity_and_round_trips() raises:
    var config = CollectionConfig.defaults(1)
    config.m = 2
    config.m0 = 2
    config.max_level = 1
    var index = HnswIndex(config)
    var metadata = MetadataIndex()
    metadata.begin_bulk()
    var ordinals = Dict[Int, Int]()
    var bitmap = Bitmap(24)
    for id in range(24):
        index._insert_prepared[-1](id, [Float32(id)], 0, False, id > 0)
        metadata.upsert(id, [DocumentField("group", PayloadValue.integer(Int64(id % 3)))])
        ordinals[id] = id
        if id % 3 == 0:
            bitmap.set(id)
    metadata.finish_bulk()
    # A line graph is connected before filtering, but every retained node is
    # separated by two rejected nodes. Payload graph construction must bridge it.
    for ordinal in range(24):
        var links = List[UInt32]()
        if ordinal > 0:
            links.append(UInt32(ordinal - 1))
        if ordinal < 23:
            links.append(UInt32(ordinal + 1))
        index.graph.set_neighbors(UInt32(ordinal), 0, links)
    var lookup = HnswIdOrdinalLookup(ordinals^, 24)
    var allowed = HnswEligibility(bitmap^, lookup)
    var prepared = index.metric.prepare_query([21.0])
    var scratch = HnswSearchScratch()
    var stats = HnswSearchStats()
    var primary: List[HnswEntry] = [HnswEntry(UInt32(0), 0)]
    var extra = List[HnswEntry]()
    var before = search(index.graph, MetricPointScorer(index.metric, prepared.copy()), primary, extra, 1, 24, allowed, scratch, stats)
    assert_equal(before[0].id, 0)
    attach_payload_graphs(index, metadata)
    assert_true(index.maximum_neighbor_count(0) > config.m0)
    stats = HnswSearchStats()
    var after = search(index.graph, MetricPointScorer(index.metric, prepared.copy()), index.entries.primary, extra, 1, 24, allowed, scratch, stats)
    assert_equal(after[0].id, 21)
    var bytes = encode_hnsw_snapshot(index, UInt64(9))
    var owned = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(9))
    assert_equal(owned.maximum_neighbor_count(0), index.maximum_neighbor_count(0))
    ensure_directory("/tmp/akasha-hnsw-payload")
    var path = String("/tmp/akasha-hnsw-payload/graph.bin")
    write_file_sync(path, bytes)
    var mapped = open_hnsw_snapshot_view(path, config, UInt64(9))
    stats = HnswSearchStats()
    var reopened = search(mapped, MetricPointScorer(index.metric, prepared.copy()), mapped.entries.primary, extra, 1, 24, allowed, scratch, stats)
    assert_equal(reopened[0].id, 21)


def test_payload_entries_keep_level_zero_and_preserve_upper_layers() raises:
    var config = CollectionConfig.defaults(1)
    config.m = 2
    config.m0 = 2
    config.max_level = 3
    var index = HnswIndex(config)
    var metadata = MetadataIndex()
    metadata.begin_bulk()
    var flags = List[Bool]()
    for id in range(24):
        index._insert_prepared[-1](id, [Float32(id)], 3 if id == 0 else 2, False, id > 0)
        metadata.upsert(id, [DocumentField("group", PayloadValue.integer(Int64(id % 3)))])
        flags.append(id % 3 == 1)
    metadata.finish_bulk()
    var upper = List[List[UInt32]]()
    for ordinal in range(24):
        var slot = UInt32(ordinal)
        for level in range(1, index.graph.level(slot) + 1):
            var row = List[UInt32]()
            for edge in range(index.graph.neighbor_count(slot, level)):
                row.append(index.graph.neighbor_at(slot, level, edge))
            upper.append(row^)
    attach_payload_graphs(index, metadata)
    var cursor = 0
    for ordinal in range(24):
        var slot = UInt32(ordinal)
        for level in range(1, index.graph.level(slot) + 1):
            assert_equal(index.graph.neighbor_count(slot, level), len(upper[cursor]))
            for edge in range(len(upper[cursor])):
                assert_equal(index.graph.neighbor_at(slot, level, edge), upper[cursor][edge])
            cursor += 1
    var ordinals = Dict[Int, Int]()
    var bitmap = Bitmap(24)
    for id in range(24):
        ordinals[id] = id
        if flags[id]:
            bitmap.set(id)
    var lookup = HnswIdOrdinalLookup(ordinals^, 24)
    var allowed = HnswEligibility(bitmap^, lookup)
    var selected = index.entries.get_entry(index.graph, allowed).value()
    assert_equal(selected.level, 0)
    assert_equal(index.graph.level(selected.slot), 2)
    var actual = index.search_allowed([22.0], 1, 24, allowed)
    assert_equal(actual[0].id, 22)
    assert_equal(index.last_search_upper_descents(), 0)
    var bytes = encode_hnsw_snapshot(index, UInt64(9))
    var owned = decode_hnsw_snapshot_owned(bytes.copy(), config, UInt64(9))
    assert_equal(owned.entries.get_entry(owned.graph, allowed).value(), selected)
    _ = owned.search_allowed([22.0], 1, 24, allowed)
    assert_equal(owned.last_search_upper_descents(), 0)
    ensure_directory("/tmp/akasha-hnsw-payload")
    var path = String("/tmp/akasha-hnsw-payload/entry-levels.bin")
    write_file_sync(path, bytes)
    var mapped = open_hnsw_snapshot_view(path, config, UInt64(9))
    assert_equal(mapped.entries.get_entry(mapped, allowed).value(), selected)
    var mapped_result = mapped.search_allowed_with_widening([22.0], 1, 24, 24, allowed)
    assert_equal(mapped_result[0].id, 22)
    assert_equal(mapped.last_search_upper_descents(), 0)


def _connected_block_fixture() raises -> HnswIndex:
    var config = CollectionConfig.defaults(1)
    config.m = 4
    config.m0 = 8
    var index = HnswIndex(config)
    for id in range(32):
        index._insert_prepared[-1](id, [Float32(id)], 0, False, id > 0)
    for id in range(32):
        var row = List[UInt32]()
        for other in range(id // 8 * 8, id // 8 * 8 + 8):
            if other != id:
                row.append(UInt32(other))
        index.graph.set_neighbors(UInt32(id), 0, row)
    return index^


def test_later_connected_fields_skip_redundant_build_work() raises:
    var one = _connected_block_fixture()
    var two = _connected_block_fixture()
    var first = MetadataIndex()
    var duplicate = MetadataIndex()
    first.begin_bulk()
    duplicate.begin_bulk()
    for id in range(32):
        first.upsert(id, [DocumentField("a", PayloadValue.string(String(id // 8)))])
        duplicate.upsert(id, [DocumentField("a", PayloadValue.string(String(id // 8))),
                             DocumentField("b", PayloadValue.string(String(id // 8)))])
    first.finish_bulk()
    duplicate.finish_bulk()
    var before = one.build_stats.distance_evaluations
    attach_payload_graphs(one, first)
    attach_payload_graphs(two, duplicate)
    assert_true(one.build_stats.distance_evaluations > before)
    assert_equal(two.build_stats.distance_evaluations, one.build_stats.distance_evaluations)
    assert_equal(two.graph.neighbor_slots, one.graph.neighbor_slots)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
