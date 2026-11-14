from akasha.index.lance_json_stream import LanceJsonBitmapTrainer
from akasha.index.lance_bitmap import LanceBitmapQuery, LanceOldRows
from akasha.index.lance_scalar import LanceScalarKey
from akasha.document.jsonb import JsonbValue
from akasha.document.jsonb_reader import parse_jsonb
from akasha.query.control import CancellationToken, QueryControl
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite
from test_lance_bitmap import _key, _ids


def _values(values: PythonObject) raises -> List[Optional[JsonbValue]]:
    var result = List[Optional[JsonbValue]]()
    for value in values:
        if Bool(py=value == Python.none()):
            result.append(None)
        else:
            var bytes = List[UInt8]()
            for byte in Python.import_module("builtins").bytes.fromhex(value):
                bytes.append(UInt8(Int(py=byte)))
            result.append(Optional(JsonbValue(Span(bytes))))
    return result^


def _source_cases(sort_memory_bytes: Optional[Int] = None) raises:
    var builtins = Python.import_module("builtins")
    var cases = Python.import_module("json").loads(builtins.open("tests/fixtures/lance-json-stream/cases.json").read())
    for row in cases:
        var known = Optional[UInt8]()
        if not Bool(py=row["target"] == Python.none()):
            known = Optional(UInt8(Int(py=row["target"])))
        var trainer = LanceJsonBitmapTrainer(String(py=row["path"]), learned_type=known.copy(), sort_memory_bytes=sort_memory_bytes)
        var expected = row["result"]
        var rejected = False
        var message = String()
        var polled = 0
        var inferred_after = 0 if known else -1
        for i in range(len(row["bodies"])):
            polled += 1
            try:
                trainer.push(_values(row["bodies"][i]), _ids(row["ids"][i]))
            except error:
                rejected = True
                message = String(error)
            if inferred_after < 0 and trainer.learned_type():
                inferred_after = polled
            if rejected:
                break
        if Bool(py=expected.__contains__("error")):
            assert_true(rejected)
            assert_equal(message, String(py=expected["error"]))
            assert_equal(polled, Int(py=expected["polled"]))
            if Bool(py=expected.__contains__("target")):
                assert_equal(trainer.learned_type().value(), UInt8(Int(py=expected["target"])))
                assert_equal(inferred_after, Int(py=expected["prefix_batches"]))
            else:
                assert_false(Bool(trainer.learned_type()))
            assert_equal(len(trainer._pending), 0)
            assert_equal(len(trainer._rows), 0)
            with assert_raises():
                _ = trainer.finish()
            continue
        assert_false(rejected)
        var index = trainer.finish()
        if inferred_after < 0:
            inferred_after = polled
        assert_equal(inferred_after, Int(py=expected["prefix_batches"]))
        assert_equal(index.target(), UInt8(Int(py=expected["target"])))
        assert_equal(index.path, String(py=row["path"]))
        var seen = 0
        for batch in expected["converted"]:
            var ids = _ids(batch["ids"])
            for i in range(len(ids)):
                var key = _key(batch["values"][i], index.target())
                assert_true(index._bitmap.lookup(key).contains(ids[i]))
                seen += 1
        assert_equal(index._bitmap._rows, seen)
        with assert_raises():
            trainer.push([], [])
        with assert_raises():
            _ = trainer.finish()
    assert_equal(len(cases), 786)



def test_original_prefix_inference_and_lazy_conversion() raises:
    _source_cases()


def test_original_source_cases_through_external_sort() raises:
    _source_cases(Optional(128))


def test_prefix_is_released_when_type_is_known() raises:
    var trainer = LanceJsonBitmapTrainer("$.v")
    trainer.push([], [])
    trainer.push([None, Optional(parse_jsonb("{}"))], [1, 2])
    assert_false(Bool(trainer.learned_type()))
    assert_equal(len(trainer._pending), 2)
    assert_equal(len(trainer._rows), 0)
    trainer.push([Optional(parse_jsonb("{v:1.5}"))], [3])
    assert_equal(trainer.learned_type().value(), UInt8(3))
    assert_equal(len(trainer._pending), 0)
    assert_equal(len(trainer._rows), 3)
    trainer.push([Optional(parse_jsonb("{v:1}"))], [4])
    assert_equal(len(trainer._pending), 0)
    var index = trainer.finish()
    assert_equal(index._bitmap.null_rows().count(), 2)
    assert_equal(index._bitmap._rows, 4)
    var null_result = index.search(LanceBitmapQuery.is_null())
    assert_equal(null_result.selected_rows.count(), 2)
    assert_equal(null_result.nulls.count(), 0)
    var value_result = index.search(LanceBitmapQuery.equals(LanceScalarKey.float_bits(0x3FF0000000000000)))
    assert_true(value_result.selected_rows.contains(4))
    assert_equal(value_result.nulls.count(), 2)


def test_updates_rebuilds_and_remaps_keep_learned_type_and_path() raises:
    var trainer = LanceJsonBitmapTrainer("$.v")
    trainer.push([Optional(parse_jsonb("{v:1.5}"))], [1])
    var old = trainer.finish()
    var update = old.trainer()
    assert_equal(update.learned_type().value(), UInt8(3))
    update.push([Optional(parse_jsonb("{v:2}"))], [2])
    var updated = update.finish_update(old, old_filter=Optional(LanceOldRows([])))
    assert_equal(old._bitmap._rows, 1)
    assert_equal(updated._bitmap._rows, 1)
    assert_equal(updated.target(), UInt8(3))
    var rebuild = updated.trainer()
    rebuild.push([Optional(parse_jsonb("{v:3}"))], [3])
    var rebuilt = rebuild.finish()
    assert_equal(rebuilt.target(), UInt8(3))
    var remapped = rebuilt.remapped({UInt64(3): Optional(UInt64.MAX)})
    assert_equal(remapped.path, "$.v")
    assert_equal(remapped._bitmap._rows, 1)
    assert_true(remapped.search(LanceBitmapQuery.equals(LanceScalarKey.float_bits(0x4008000000000000))).selected_rows.contains(UInt64.MAX))
    var failed = old.trainer()
    with assert_raises():
        failed.push([Optional(parse_jsonb("{v:true}"))], [4])
    with assert_raises():
        _ = failed.finish_update(old)
    assert_equal(old._bitmap._rows, 1)


def test_aggregate_budget_abort_and_all_null_rebuild() raises:
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=1)
    var budgeted = LanceJsonBitmapTrainer("$", control=Optional(control.copy()))
    budgeted.push([None], [0])
    with assert_raises():
        budgeted.push([None], [1])
    assert_equal(len(budgeted._pending), 0)
    var aborted = LanceJsonBitmapTrainer("$")
    aborted.push([None], [1])
    aborted.abort()
    with assert_raises():
        _ = aborted.finish()
    var fixed = LanceJsonBitmapTrainer("$.a", learned_type=Optional(UInt8(2)))
    fixed.push([None, Optional(parse_jsonb("{}"))], [1, 2])
    var index = fixed.finish()
    assert_equal(index.target(), UInt8(2))
    assert_equal(index.search(LanceBitmapQuery.is_null()).selected_rows.count(), 2)
    var empty_update = index.trainer()
    var retained = empty_update.finish_update(index, old_filter=Optional(LanceOldRows([1])))
    assert_equal(retained.target(), UInt8(2))
    assert_true(retained.search(LanceBitmapQuery.is_null()).selected_rows.contains(1))
    assert_equal(retained._bitmap._rows, 1)
    assert_equal(index._bitmap._rows, 2)
    var nulls = LanceJsonBitmapTrainer("$")
    nulls.push([None, Optional(parse_jsonb("null"))], [1, 2])
    var defaulted = nulls.finish()
    assert_equal(defaulted.target(), UInt8(4))
    var bad_update = defaulted.trainer()
    with assert_raises():
        bad_update.push([Optional(parse_jsonb("1"))], [3])


def test_failures_close_training_and_preserve_old_index() raises:
    var trainer = LanceJsonBitmapTrainer("$", max_rows=1)
    trainer.push([Optional(parse_jsonb("1"))], [1])
    with assert_raises():
        trainer.push([Optional(parse_jsonb("2"))], [2])
    assert_equal(len(trainer._rows), 0)
    with assert_raises():
        _ = trainer.finish()
    var mismatch = LanceJsonBitmapTrainer("$")
    with assert_raises():
        mismatch.push([None], [])
    var bytes = LanceJsonBitmapTrainer("$", max_bytes=1)
    with assert_raises():
        bytes.push([], [])
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=100)
    var cancelled = LanceJsonBitmapTrainer("$", control=Optional(control.copy()))
    cancelled.push([None], [0])
    token.cancel()
    with assert_raises():
        _ = cancelled.finish()
    assert_equal(len(cancelled._pending), 0)
    var builder = LanceJsonBitmapTrainer("$")
    builder.push([Optional(parse_jsonb("1"))], [0])
    var old = builder.finish()
    var wrong_path = LanceJsonBitmapTrainer("$.a", learned_type=Optional(UInt8(2)))
    with assert_raises():
        _ = wrong_path.finish_update(old)
    assert_equal(old._bitmap._rows, 1)
    var unknown = LanceJsonBitmapTrainer("$")
    with assert_raises():
        _ = unknown.finish_update(old)
    var initial = LanceJsonBitmapTrainer("$", max_rows=2)
    initial.push([Optional(parse_jsonb("1")), Optional(parse_jsonb("2"))], [1, 2])
    var limited = initial.finish()
    var overflow = limited.trainer()
    overflow.push([Optional(parse_jsonb("3"))], [3])
    with assert_raises():
        _ = overflow.finish_update(limited)
    assert_equal(len(overflow._rows), 0)
    assert_equal(limited._bitmap._rows, 2)
    with assert_raises():
        _ = overflow.finish()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
