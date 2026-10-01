from akasha import CollectionConfig, ReadSnapshot, PersistentCollection
from akasha.query.control import CancellationToken, QueryControl
from akasha.api.scanner import ScanBatch
from akasha.document.point_state import PointField, PointState
from akasha.document.vector_value import VectorValue
from akasha.document.vector_schema import legacy_vector_fields
from akasha.storage.memtable import MemTableEntry
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable
from akasha.storage.read_generation import ReadGenerationCache
from akasha.storage.filesystem import path_exists
from bindings.arrow_export import (
    ArrowColumn,
    export_scan_batch,
    scanner_schema,
    _release_array,
)
from std.memory import ArcPointer
from std.python import Python
from std.testing import (
    assert_equal,
    assert_raises,
    assert_true,
    assert_false,
    TestSuite,
)


def _batch(
    pins: ArcPointer[GenerationPinRegistry], count: Int
) raises -> ScanBatch:
    var table = MemTable(2)
    for id in range(count):
        table.apply_upsert(id, UInt64(id + 1), [Float32(id), 1.0])
    var cache = ReadGenerationCache()
    var snapshot = ReadSnapshot(
        cache.acquire(
            CollectionConfig.defaults(2), 0, UInt64(count), table, pins
        )
    )
    var scanner = snapshot.scanner(count)
    var batch = scanner.next_batch()
    snapshot.close()
    cache.reset()
    scanner.close()
    return batch.take()


def _control() raises -> QueryControl:
    var token = CancellationToken()
    return QueryControl(token, max_candidates=Int.MAX)


def test_real_pyarrow_slice_retains_borrowed_pointer_and_last_pin() raises:
    var pins = ArcPointer(GenerationPinRegistry())
    var source = _batch(pins, 1)
    var columns: List[ArrowColumn] = [ArrowColumn("vector", 3)]
    var exported = export_scan_batch(source, columns, 1024, _control())
    var pa = Python.import_module("pyarrow")
    var batch = pa.RecordBatch._import_from_c(
        exported.address(), scanner_schema(columns, 2)
    )
    assert_equal(
        Int(py=batch.column(0).values.buffers()[1].address),
        Int(Span(source.entry(0).values()).unsafe_ptr()),
    )
    assert_equal(exported._header[8], Int64(0))
    assert_equal(exported.borrowed_bytes, 8)
    assert_equal(exported.materialized_bytes, 0)
    _ = source^
    _ = exported^
    var values = batch.column(0).values.slice(1, 1)
    _ = batch^
    Python.import_module("gc").collect()
    assert_equal(pins[].active_count(), 1)
    assert_equal(Float32(py=values[0].as_py()), Float32(1.0))
    _ = values^
    Python.import_module("gc").collect()
    assert_equal(pins[].active_count(), 0)


def test_gathered_buffers_are_independent_of_source_and_export_header() raises:
    var pins = ArcPointer(GenerationPinRegistry())
    var source = _batch(pins, 2)
    var columns: List[ArrowColumn] = [
        ArrowColumn("id", 1),
        ArrowColumn("vector", 3),
    ]
    var exported = export_scan_batch(source, columns, 1024, _control())
    assert_equal(exported.borrowed_bytes, 0)
    assert_equal(exported.materialized_bytes, 32)
    _ = source^
    assert_equal(pins[].active_count(), 0)
    var pa = Python.import_module("pyarrow")
    var batch = pa.RecordBatch._import_from_c(
        exported.address(), scanner_schema(columns, 2)
    )
    _ = exported^
    batch.validate(full=True)
    assert_equal(Int(py=batch.column(0)[1].as_py()), 1)
    assert_equal(Float32(py=batch.column(1)[1].as_py()[0]), Float32(1.0))


def test_relocated_child_owns_data_after_parent_release() raises:
    var pins = ArcPointer(GenerationPinRegistry())
    var source = _batch(pins, 1)
    var columns: List[ArrowColumn] = [ArrowColumn("vector", 3)]
    var exported = export_scan_batch(source, columns, 1024, _control())
    _ = source^
    # Move the fixed-list child as the C Data contract permits, then immediately
    # release its parent. Only private_data can locate the moved child's owner.
    var children = Pointer[Int64, MutUntrackedOrigin](
        unsafe_from_address=Int(exported._header[6])
    )
    var child = Pointer[Int64, MutUntrackedOrigin](
        unsafe_from_address=Int(children[])
    )
    var moved = List[Int64](length=10, fill=Int64(0))
    for index in range(10):
        moved[index] = child[unsafe_offset=index]
    child[unsafe_offset=8] = 0
    _release_array(
        Pointer[NoneType, MutUntrackedOrigin](
            unsafe_from_address=exported.address()
        )
    )
    _ = exported^
    assert_equal(pins[].active_count(), 1)
    var pa = Python.import_module("pyarrow")
    var array = pa.Array._import_from_c(
        Int(Span(moved).unsafe_ptr()), pa.list_(pa.float32(), 2)
    )
    assert_equal(moved[8], Int64(0))
    assert_equal(Float32(py=array[0].as_py()[1]), Float32(1.0))
    _ = array^
    Python.import_module("gc").collect()
    assert_equal(pins[].active_count(), 0)


def test_unconsumed_arrays_and_failed_exports_release_roots() raises:
    var pins = ArcPointer(GenerationPinRegistry())
    var source = _batch(pins, 1)
    var columns: List[ArrowColumn] = [ArrowColumn("vector", 3)]
    var exported = export_scan_batch(source, columns, 1024, _control())
    _ = source^
    assert_equal(pins[].active_count(), 1)
    _ = exported^
    assert_equal(pins[].active_count(), 0)
    source = _batch(pins, 1)
    columns.append(ArrowColumn("id", 1))
    # Vector borrowed first; the later owned column exceeds the budget. Partial
    # child destruction must return the additional root reference.
    with assert_raises():
        _ = export_scan_batch(source, columns, 1, _control())
    assert_equal(pins[].active_count(), 1)
    _ = source^
    assert_equal(pins[].active_count(), 0)


def test_last_arrow_release_reclaims_compacted_files_after_collection_close() raises:
    var path = String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-arrow-lease-"
        )
    )
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1.0, 2.0])
    collection.flush()
    var old_base = path + "/segment-base-1.bin"
    assert_true(path_exists(old_base))
    var snapshot = collection.snapshot()
    var scanner = snapshot.scanner(1)
    var source = scanner.next_batch()
    var columns: List[ArrowColumn] = [ArrowColumn("vector", 3)]
    var exported = export_scan_batch(source.value(), columns, 1024, _control())
    var pa = Python.import_module("pyarrow")
    var batch = pa.RecordBatch._import_from_c(
        exported.address(), scanner_schema(columns, 2)
    )
    _ = exported^
    _ = source^
    snapshot.close()
    scanner.close()
    collection.upsert(2, [3.0, 4.0])
    collection.flush()
    collection.compact()
    var registry = collection._pins.copy()
    collection.close()
    assert_true(path_exists(old_base))
    var values = batch.column(0).values.slice(1, 1)
    _ = batch^
    assert_equal(Float32(py=values[0].as_py()), Float32(2.0))
    assert_true(path_exists(old_base))
    _ = values^
    Python.import_module("gc").collect()
    assert_equal(registry[].active_count(), 0)
    assert_equal(registry[].cleanup_error(), "")
    assert_false(path_exists(old_base))
    Python.import_module("shutil").rmtree(path)


def test_legacy_dense_export_rejects_missing_default_before_exposing_memory() raises:
    var table = MemTable(2)
    var point = PointState.live(
        1,
        1,
        0,
        [PointField(2, VectorValue.dense[DType.float16]([Float16(1)]))],
        [],
    )
    table.put(MemTableEntry.from_point(point))
    var cache = ReadGenerationCache()
    var snapshot = ReadSnapshot(
        cache.acquire(
            CollectionConfig.defaults(2),
            0,
            1,
            table,
            ArcPointer(GenerationPinRegistry()),
        )
    )
    var scanner = snapshot.scanner(1)
    var batch = scanner.next_batch()
    var columns: List[ArrowColumn] = [ArrowColumn("vector", 3)]
    with assert_raises():
        _ = export_scan_batch(batch.value(), columns, 1024, _control())
    snapshot.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def test_typed_column_rejects_schema_larger_than_borrowed_allocation() raises:
    var source = _batch(ArcPointer(GenerationPinRegistry()), 1)
    var wrong_schema = legacy_vector_fields(CollectionConfig.defaults(3))
    var columns: List[ArrowColumn] = [
        ArrowColumn("vector", 10, String(), Optional(wrong_schema[0].copy()))
    ]
    with assert_raises(contains="schema does not match"):
        _ = export_scan_batch(source, columns, 1024, _control())


def test_export_observes_cancel_and_deadline_before_exposing_buffers() raises:
    var pins = ArcPointer(GenerationPinRegistry())
    var source = _batch(pins, 2)
    var columns: List[ArrowColumn] = [ArrowColumn("vector", 3)]
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=10)
    token.cancel()
    with assert_raises(contains="cancelled"):
        _ = export_scan_batch(source, columns, 1024, control)
    var ready = CancellationToken()
    var expired = QueryControl(ready, max_candidates=10, deadline_ns=1)
    with assert_raises(contains="deadline"):
        _ = export_scan_batch(source, columns, 1024, expired)
    _ = source^
    assert_equal(pins[].active_count(), 0)
