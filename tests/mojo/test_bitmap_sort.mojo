from akasha.index.bitmap_sort import ExternalBitmapSort
from akasha.index.lance_bitmap import LanceBitmapIndex, LanceBitmapRow
from akasha.index.lance_json_stream import LanceJsonBitmapIndex, LanceJsonBitmapTrainer
from akasha.index.lance_scalar import LanceScalarKey
from akasha.storage.json_bitmap_codec import encode_json_bitmap
from akasha.document.jsonb_reader import parse_jsonb
from akasha.query.control import CancellationToken, QueryControl
from std.ffi import c_int, external_call
from std.python import Python
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite


def test_spilled_sort_all_types_matches_owned_builder() raises:
    var keys: List[LanceScalarKey] = [LanceScalarKey.boolean(False), LanceScalarKey.integer(-99),
        LanceScalarKey.float_bits(0x8000000000000000), LanceScalarKey.text("雪"),
        LanceScalarKey.binary([UInt8(255), 0])]
    for key in keys:
        var sorter = ExternalBitmapSort(memory_bytes=256)
        var rows = List[LanceBitmapRow]()
        for i in range(50):
            var value = LanceScalarKey.null(key.target) if i % 3 == 0 else key.copy()
            if key.target == 3 and i % 5 == 0:
                value = LanceScalarKey.float_bits(0x7FF8000000000001)
            rows.append(LanceBitmapRow(value^, UInt64(i)))
            sorter.push(rows[i].copy())
        assert_true(sorter.spill_runs > 2)
        assert_true(sorter.peak_buffer_bytes <= 256)
        sorter.prepare(key.target)
        assert_true(sorter.merge_passes > 1)
        var empty = LanceBitmapIndex(key.target)
        var actual = LanceJsonBitmapIndex("$", empty.merge_stream(sorter), True)
        var expected = LanceJsonBitmapIndex("$", LanceBitmapIndex.build(key.target, rows), True)
        assert_equal(encode_json_bitmap("data", actual), encode_json_bitmap("data", expected))
        var fd = sorter._file.value().handle
        sorter.abort()
        assert_equal(external_call["fcntl", c_int, num_fixed_args=2](c_int(fd), c_int(1)), -1)


def test_in_memory_empty_stability_and_oversized_row() raises:
    var empty = ExternalBitmapSort(memory_bytes=256)
    empty.prepare(2)
    assert_false(Bool(empty.next()))
    assert_false(Bool(empty._file))
    var sorter = ExternalBitmapSort(memory_bytes=1)
    for i in range(9):
        sorter.push(LanceBitmapRow(LanceScalarKey.text("same"), UInt64(i)))
    sorter.prepare(4)
    for i in range(9):
        var row = sorter.next()
        assert_equal(row.value().id, UInt64(i))
    assert_false(Bool(sorter.next()))
    assert_true(sorter.peak_buffer_bytes > 1)
    var limited = ExternalBitmapSort(max_row_bytes=1)
    with assert_raises():
        limited.push(LanceBitmapRow(LanceScalarKey.integer(1), 0))
    assert_true(limited._closed)


def test_spill_failures_cancel_corruption_and_cleanup() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var sorter = ExternalBitmapSort(memory_bytes=1, directory=path.copy())
    sorter.push(LanceBitmapRow(LanceScalarKey.integer(2), 0))
    sorter.push(LanceBitmapRow(LanceScalarKey.integer(1), 1))
    assert_equal(len(Python.import_module("os").listdir(path)), 0)
    var fd = sorter._file.value().handle
    assert_equal(external_call["ftruncate", c_int](c_int(fd), Int64(0)), 0)
    with assert_raises():
        sorter.prepare(2)
    assert_false(Bool(sorter._file))
    assert_equal(external_call["fcntl", c_int, num_fixed_args=2](c_int(fd), c_int(1)), -1)
    var missing = ExternalBitmapSort(memory_bytes=1, directory=path + "/missing")
    missing.push(LanceBitmapRow(LanceScalarKey.integer(2), 0))
    with assert_raises(contains="create"):
        missing.push(LanceBitmapRow(LanceScalarKey.integer(1), 1))
    assert_true(missing._closed)
    var disk = ExternalBitmapSort(memory_bytes=1, disk_bytes=1, directory=path.copy())
    disk.push(LanceBitmapRow(LanceScalarKey.integer(2), 0))
    with assert_raises(contains="disk byte"):
        disk.push(LanceBitmapRow(LanceScalarKey.integer(1), 1))
    assert_false(Bool(disk._file))
    var merge_limit = ExternalBitmapSort(memory_bytes=1, disk_bytes=80, directory=path.copy())
    merge_limit.push(LanceBitmapRow(LanceScalarKey.integer(2), 0))
    merge_limit.push(LanceBitmapRow(LanceScalarKey.integer(1), 1))
    with assert_raises(contains="disk byte"):
        merge_limit.prepare(2)
    assert_false(Bool(merge_limit._file))
    var token = CancellationToken()
    var cancel = ExternalBitmapSort(memory_bytes=1, directory=path.copy(),
        control=Optional(QueryControl(token, max_candidates=10)))
    cancel.push(LanceBitmapRow(LanceScalarKey.integer(2), 0))
    cancel.push(LanceBitmapRow(LanceScalarKey.integer(1), 1))
    token.cancel()
    with assert_raises(contains="cancel"):
        cancel.prepare(2)
    assert_false(Bool(cancel._file))
    assert_equal(len(Python.import_module("os").listdir(path)), 0)
    directory.cleanup()


def test_external_training_null_prefix_update_and_final_limit() raises:
    var trainer = LanceJsonBitmapTrainer("$", max_bytes=4096, sort_memory_bytes=Optional(256))
    for i in range(100):
        trainer.push([None], [UInt64(i)])
    assert_false(Bool(trainer.learned_type()))
    assert_equal(len(trainer._pending), 0)
    trainer.push([Optional(parse_jsonb("3"))], [100])
    var index = trainer.finish()
    assert_equal(index.target(), UInt8(2))
    assert_equal(index._bitmap.null_rows().count(), 100)
    assert_equal(index._bitmap.lookup(LanceScalarKey.integer(3)).values(), [UInt64(100)])
    assert_false(Bool(trainer._sorter.value()._file))
    var update = LanceJsonBitmapTrainer("$", learned_type=Optional(UInt8(2)), sort_memory_bytes=Optional(128))
    for i in range(10):
        update.push([Optional(parse_jsonb("3"))], [UInt64(101+i)])
    var updated = update.finish_update(index)
    assert_equal(updated._bitmap.lookup(LanceScalarKey.integer(3)).count(), 11)
    assert_equal(index._bitmap.lookup(LanceScalarKey.integer(3)).count(), 1)
    var limited = LanceJsonBitmapTrainer("$", max_bytes=512, sort_memory_bytes=Optional(128))
    for i in range(10):
        limited.push([Optional(parse_jsonb(String(i)))], [UInt64(i)])
    with assert_raises(contains="byte limit"):
        _ = limited.finish()
    assert_false(Bool(limited._sorter.value()._file))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
