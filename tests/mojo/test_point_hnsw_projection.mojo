from akasha.common.config import CollectionConfig
from akasha.document.point_state import PointField, PointState
from akasha.document.vector_value import VectorValue
from akasha.index.hnsw_rebuild import HnswRebuild, build_hnsw
from akasha.storage.memtable import MemTable, MemTableEntry
from akasha.storage.read_generation import ReadGenerationCache
from akasha.storage.generation_pins import GenerationPinRegistry
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def _entry(
    id: Int, sequence: UInt64, document_sequence: UInt64
) raises -> MemTableEntry:
    var fields = List[PointField]()
    if document_sequence:
        fields.append(PointField(0, VectorValue.dense[DType.float32]([1, 0])))
    fields.append(PointField(2, VectorValue.dense[DType.float16]([Float16(2)])))
    var point = PointState.live(id, sequence, document_sequence, fields^, [])
    return MemTableEntry.from_point(point)


def test_default_hnsw_build_skips_named_only_points() raises:
    var table = MemTable(2)
    table.put(_entry(1, 7, 1))
    table.put(_entry(2, 8, 0))
    var graph = build_hnsw(table, CollectionConfig.defaults(2))
    assert_equal(graph.point_count(), 1)


def test_rebuild_journal_ignores_named_updates_and_deletes_removed_default() raises:
    var config = CollectionConfig.defaults(2)
    var table = MemTable(2)
    table.put(_entry(1, 1, 1))
    var cache = ReadGenerationCache()
    var root = cache.acquire(
        config, 0, 1, table, ArcPointer(GenerationPinRegistry())
    )
    var job = HnswRebuild(root^)
    var graph = job.build()
    table.put(_entry(1, 2, 1))
    job.record(table, [1], 2)
    assert_equal(job.tail.slot_count(), 0)
    assert_equal(job.sequence, UInt64(2))
    table.put(_entry(1, 3, 0))
    job.record(table, [1], 3)
    var tail = job.take_tail()
    job.catch_up(tail, graph)
    assert_false(graph.contains_current(1))
    assert_equal(graph.current_point_count(), 0)
    table.put(_entry(1, 4, 4))
    job.record(table, [1], 4)
    var reinsert = job.take_tail()
    job.catch_up(reinsert, graph)
    assert_true(graph.contains_current(1))
    assert_equal(graph.current_point_count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
