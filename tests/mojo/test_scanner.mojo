from akasha import (
    CollectionConfig,
    ReadSnapshot,
    CancellationToken,
    QueryControl,
)
from akasha.api.scanner import ReadScanner
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.query.filter_ast import FilterCondition, FilterExpression
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable
from akasha.storage.read_generation import ReadGenerationCache
from std.memory import ArcPointer
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def test_scanner_batches_share_pinned_rows_after_snapshot_close() raises:
    var pins = ArcPointer(GenerationPinRegistry())
    var table = MemTable(2)
    for id in range(7):
        table.apply_upsert(id, UInt64(id + 1), [Float32(id), 1.0])
    var cache = ReadGenerationCache()
    var snapshot = ReadSnapshot(
        cache.acquire(CollectionConfig.defaults(2), 0, 7, table, pins)
    )
    var scanner = snapshot.scanner(3)
    var source = snapshot._acquire()
    var expected = Int(
        Span(source[].run(0).memtable.entry_ref_at(0).values()).unsafe_ptr()
    )
    snapshot.close()
    cache.reset()
    var first = scanner.next_batch()
    assert_equal(first.value().row_count(), 3)
    assert_equal(
        Int(Span(first.value().entry(0).values()).unsafe_ptr()), expected
    )
    _ = source^
    var second = scanner.next_batch()
    assert_equal(second.value().entry(0).id, 3)
    assert_equal(second.value().row_count(), 3)
    var third = scanner.next_batch()
    assert_equal(third.value().entry(0).id, 6)
    assert_equal(third.value().row_count(), 1)
    assert_false(Bool(scanner.next_batch()))
    scanner.close()
    assert_equal(first.value().entry(0).values()[0], Float32(0.0))
    assert_equal(pins[].active_count(), 1)
    _ = first^
    _ = second^
    _ = third^
    assert_equal(pins[].active_count(), 0)


def test_scanner_latest_visibility_filter_and_stable_capture() raises:
    var pins = ArcPointer(GenerationPinRegistry())
    var table = MemTable(1)
    table.apply_upsert(1, 1, [1.0])
    table.apply_upsert(2, 2, [2.0])
    var cache = ReadGenerationCache()
    _ = cache.acquire(CollectionConfig.defaults(1), 0, 2, table, pins)
    var fields: List[DocumentField] = [
        DocumentField("keep", PayloadValue.boolean(True))
    ]
    table.apply_document_upsert(1, 3, [9.0], fields^)
    cache.record(table, [1], 3)
    table.apply_delete(2, 4)
    cache.record(table, [2], 4)
    var snapshot = ReadSnapshot(
        cache.acquire(CollectionConfig.defaults(1), 0, 4, table, pins)
    )
    var filter = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    var scanner = snapshot.scanner(2, Optional(filter^))
    table.apply_upsert(1, 5, [99.0])
    cache.record(table, [1], 5)
    var batch = scanner.next_batch()
    assert_equal(batch.value().row_count(), 1)
    assert_equal(batch.value().entry(0).id, 1)
    assert_equal(batch.value().entry(0).values()[0], Float32(9.0))
    assert_false(Bool(scanner.next_batch()))
    snapshot.close()


def test_scanner_empty_close_and_bounds() raises:
    var table = MemTable(1)
    var pins = ArcPointer(GenerationPinRegistry())
    var cache = ReadGenerationCache()
    var snapshot = ReadSnapshot(
        cache.acquire(CollectionConfig.defaults(1), 0, 0, table, pins)
    )
    with assert_raises():
        _ = snapshot.scanner(0)
    with assert_raises():
        _ = snapshot.scanner(-1)
    var scanner = snapshot.scanner(1)
    assert_false(Bool(scanner.next_batch()))
    assert_false(Bool(scanner.next_batch()))
    scanner.close()
    scanner.close()
    with assert_raises():
        _ = scanner.next_batch()
    snapshot.close()
    with assert_raises():
        _ = snapshot.scanner(1)


def test_cancel_and_budget_fail_terminally_without_leaking_root() raises:
    var table = MemTable(1)
    for id in range(5):
        table.apply_upsert(id, UInt64(id + 1), [Float32(id)])
    var pins = ArcPointer(GenerationPinRegistry())
    var cache = ReadGenerationCache()
    var snapshot = ReadSnapshot(
        cache.acquire(CollectionConfig.defaults(1), 0, 5, table, pins)
    )
    var cancelled = snapshot.scanner(2)
    var budget = snapshot.scanner(2)
    snapshot.close()
    cache.reset()
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=3)
    var first = budget.next(control)
    assert_equal(first.value().row_count(), 2)
    with assert_raises():
        _ = budget.next(control)
    with assert_raises():
        _ = budget.next_batch()
    token.cancel()
    with assert_raises():
        _ = cancelled.next(control)
    assert_equal(first.value().entry(0).id, 0)
    _ = first^
    assert_equal(pins[].active_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
