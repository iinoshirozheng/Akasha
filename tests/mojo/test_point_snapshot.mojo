from akasha.api.snapshot import ReadSnapshot
from akasha.common.config import CollectionConfig
from akasha.document.point_state import PointField, PointState
from akasha.document.vector_schema import (
    FieldCatalog,
    VectorFieldSpec,
    legacy_vector_fields,
)
from akasha.document.vector_value import VectorValue
from akasha.query.filter_ast import FilterExpression, FilterCondition
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable, MemTableEntry
from akasha.storage.read_generation import ReadGenerationCache, HEAD_MAX_BYTES
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, TestSuite


def _catalog() raises -> ArcPointer[FieldCatalog]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(2))
    fields.append(VectorFieldSpec(2, "image", 0, 2, 0, 0, 2))
    return ArcPointer(FieldCatalog(1, 0, fields^))


def _point(
    id: Int, seq: UInt64, dense: Bool, named: Bool, score: Float16
) raises -> MemTableEntry:
    var fields = List[PointField]()
    if dense:
        fields.append(
            PointField(0, VectorValue.dense[DType.float32]([Float32(id), 0]))
        )
    if named:
        fields.append(
            PointField(2, VectorValue.dense[DType.float16]([score, Float16(0)]))
        )
    var payload: List[DocumentField] = [
        DocumentField("group", PayloadValue.string("present"))
    ]
    var point = PointState.live(
        id, seq, seq if dense else UInt64(0), fields^, payload^
    )
    return MemTableEntry.from_point(point)


def test_typed_snapshot_layers_preserve_owners_and_field_absence() raises:
    var config = CollectionConfig.defaults(2)
    var catalog = _catalog()
    var pins = ArcPointer(GenerationPinRegistry())
    var table = MemTable(2)
    table.put(_point(1, 1, True, True, 2))
    table.put(_point(2, 2, False, True, 9))
    var cache = ReadGenerationCache()
    var old = ReadSnapshot(
        cache.acquire(config, 0, 2, table, pins, Optional(catalog))
    )
    var old_owner = old.get_point(1).value().field_at(1).address()
    table.put(_point(1, 3, True, True, 5))
    table.put(_point(2, 4, False, False, 0))
    table.put(_point(3, 5, False, True, 7))
    cache.record(table, [1, 2, 3], 5)
    var current = ReadSnapshot(
        cache.acquire(config, 0, 5, table, pins, Optional(catalog))
    )
    var query = VectorValue.dense[DType.float16]([Float16(1), Float16(0)])
    var before = old.search_field("image", query, 5)
    var after = current.search_field("image", query, 5)
    assert_equal(len(before), 2)
    assert_equal(before[0].id, 2)
    assert_equal(len(after), 2)
    assert_equal(after[0].id, 3)
    assert_equal(after[1].id, 1)
    assert_equal(old.get_point(1).value().field_at(1).address(), old_owner)
    assert_equal(
        current.get_point(1).value().field_at(1).address(),
        table.entry_ref_at(0).to_point().field_at(1).address(),
    )
    assert_equal(len(current.search_dot([1, 0], 5)), 1)
    assert_false(Bool(current.get(2)))
    assert_equal(len(current.documents()), 1)
    assert_equal(current.get(1).value().sequence, UInt64(3))
    var filter = FilterExpression.condition(
        FilterCondition.equal("group", PayloadValue.string("present"))
    )
    assert_equal(len(current.search_dot_where([1, 0], 5, filter)), 1)
    assert_equal(len(current.search_dot_batch([[1, 0]], 5)[0]), 1)
    assert_equal(
        len(current.search_field("image", query, 5, Optional(filter^))), 2
    )
    var scanner = current.scanner(1)
    current.close()
    var count = 0
    var batch = scanner.next_batch()
    while Bool(batch):
        count += batch.value().row_count()
        batch = scanner.next_batch()
    assert_equal(count, 3)
    assert_equal(old.get_point(1).value().field_at(1).address(), old_owner)
    with assert_raises():
        _ = current.search_field("image", query, 1)
    old.close()


def test_named_updates_preserve_legacy_document_version_in_snapshot() raises:
    var catalog = _catalog()
    var table = MemTable(2)
    var entry = _point(1, 7, True, True, 9)
    entry.document_sequence = 2
    table.put(entry^)
    var cache = ReadGenerationCache()
    var snapshot = ReadSnapshot(
        cache.acquire(
            CollectionConfig.defaults(2),
            0,
            7,
            table,
            ArcPointer(GenerationPinRegistry()),
            Optional(catalog),
        )
    )
    assert_equal(snapshot.get(1).value().sequence, UInt64(2))
    assert_equal(snapshot.get_point(1).value().sequence, UInt64(7))
    var empty = VectorValue.dense[DType.float16]([Float16(1), Float16(0)])
    with assert_raises():
        _ = snapshot.search_field("missing", empty, 1)
    snapshot.close()


def test_named_only_and_empty_sparse_keep_legacy_search_empty() raises:
    var catalog = _catalog()
    var fields: List[PointField] = [
        PointField(1, VectorValue.sparse([])),
        PointField(
            2, VectorValue.dense[DType.float16]([Float16(1), Float16(0)])
        ),
    ]
    var point = PointState.live(1, 1, 0, fields^, [])
    var table = MemTable(2)
    table.put(MemTableEntry.from_point(point))
    var cache = ReadGenerationCache()
    var root = cache.acquire(
        CollectionConfig.defaults(2),
        0,
        1,
        table,
        ArcPointer(GenerationPinRegistry()),
        Optional(catalog),
    )
    assert_equal(root[].dense_run()[].memtable.live_count(), 0)
    var snapshot = ReadSnapshot(root^)
    assert_equal(len(snapshot.search_dot([1, 0], 5)), 0)
    assert_equal(len(snapshot.search_sq8_dot([1, 0], 5)), 0)
    assert_equal(
        len(snapshot.search_pq_dot([1, 0], 5, subquantizers=1, centroids=1)), 0
    )
    assert_equal(
        len(snapshot.get_point(1).value().field_at(0).value().sparse_values()),
        0,
    )
    snapshot.close()


def test_native_field_bytes_trigger_bounded_head_rollover_without_data_copy() raises:
    var config = CollectionConfig.defaults(2)
    var fields = legacy_vector_fields(config)
    fields.append(VectorFieldSpec(2, "large", 3, 5, 3, 0, HEAD_MAX_BYTES * 8))
    var catalog = ArcPointer(FieldCatalog(1, 0, fields^))
    var table = MemTable(2)
    var cache = ReadGenerationCache()
    var pins = ArcPointer(GenerationPinRegistry())
    var before = cache.acquire(config, 0, 0, table, pins, Optional(catalog))
    var vector = VectorValue.binary(
        HEAD_MAX_BYTES * 8, List[UInt8](length=HEAD_MAX_BYTES, fill=UInt8(0))
    )
    var point = PointState.live(1, 1, 0, [PointField(2, vector^)], [])
    point.validate(catalog[])
    table.put(MemTableEntry.from_point(point))
    cache.record(table, [1], 1)
    assert_equal(cache.stats.rollovers, 1)
    assert_equal(cache.head_count(), 0)
    var snapshot = ReadSnapshot(
        cache.acquire(config, 0, 1, table, pins, Optional(catalog))
    )
    assert_equal(
        snapshot.get_point(1).value().field_at(0).address(),
        point.field_at(0).address(),
    )
    assert_equal(before[].visible_count, 0)
    snapshot.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
