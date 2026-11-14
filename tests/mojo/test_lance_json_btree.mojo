from akasha.index.lance_json_btree import LanceJsonBTreeTrainer
from akasha.index.lance_bitmap import LanceBitmapQuery, LanceBitmapBound
from akasha.index.lance_scalar import LanceScalarKey
from akasha.document.jsonb_reader import parse_jsonb
from std.python import Python
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite
from test_lance_json_stream import _values
from test_lance_bitmap import _key, _ids


def test_original_json_stream_corpus_through_btree() raises:
    var builtins = Python.import_module("builtins")
    var cases = Python.import_module("json").loads(builtins.open("tests/fixtures/lance-json-stream/cases.json").read())
    for row in cases:
        var known = Optional[UInt8]()
        if not Bool(py=row["target"] == Python.none()):
            known = Optional(UInt8(Int(py=row["target"])))
        var trainer = LanceJsonBTreeTrainer(String(py=row["path"]), learned_type=known.copy(), sort_memory_bytes=128)
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
            assert_equal(len(trainer._input._pending), 0)
            assert_equal(len(trainer._input._rows), 0)
            with assert_raises():
                _ = trainer.finish("data", 2, 0, 0)
            continue
        assert_false(rejected)
        var index = trainer.finish("data", 2, 0, 0)
        if inferred_after < 0:
            inferred_after = polled
        assert_equal(inferred_after, Int(py=expected["prefix_batches"]))
        assert_equal(index.target(), UInt8(Int(py=expected["target"])))
        assert_equal(index._btree.pages.path, String(py=row["path"]))
        var decoded = Dict[UInt64, LanceScalarKey]()
        for page in range(len(index._btree.pages.locations)):
            for leaf_row in index._btree.pages.read_page(page):
                decoded[leaf_row.id] = leaf_row.key.copy()
        var seen = 0
        for batch in expected["converted"]:
            var ids = _ids(batch["ids"])
            for i in range(len(ids)):
                var key = _key(batch["values"][i], index.target())
                assert_equal(decoded[ids[i]].compare(key), 0)
                seen += 1
        assert_equal(index._btree.pages.row_count, seen)
        with assert_raises():
            trainer.push([], [])
        with assert_raises():
            _ = trainer.finish("data", 2, 0, 0)
    assert_equal(len(cases), 786)


def test_json_btree_null_prefix_learned_type_and_substitution_guards() raises:
    var trainer = LanceJsonBTreeTrainer("v", sort_memory_bytes=128)
    trainer.push([None, Optional(parse_jsonb("{}"))], [0, 1])
    assert_false(Bool(trainer.learned_type()))
    trainer.push([Optional(parse_jsonb("{\"v\":2}"))], [2])
    assert_equal(trainer.learned_type().value(), UInt8(2))
    var index = trainer.finish("data", 2, 17, 99)
    var equals = LanceBitmapQuery.equals(LanceScalarKey.integer(2))
    var covered = index.try_search("json_get_int", Optional(String("v")), equals)
    assert_true(Bool(covered))
    assert_equal(covered.value().rows.true_rows().values(), [UInt64(2)])
    assert_equal(covered.value().rows.nulls.values(), [UInt64(0), 1])
    assert_false(Bool(index.try_search("json_get_int", Optional(String("$.other")), equals)))
    assert_false(Bool(index.try_search("json_get_int", Optional(String("v")), LanceBitmapQuery.equals(LanceScalarKey.null(2)))))
    assert_false(Bool(index.try_search("json_get_int", Optional(String("v")), LanceBitmapQuery.is_in([LanceScalarKey.null(2)]))))
    assert_false(Bool(index.try_search("json_get_int", Optional(String("v")), LanceBitmapQuery.range_of(LanceBitmapBound(), LanceBitmapBound()))))
    var empty_in = index.try_search("json_get_int", Optional(String("v")), LanceBitmapQuery.is_in([]))
    assert_true(Bool(empty_in))
    assert_equal(empty_in.value().rows.selected_rows.count(), 0)
    assert_equal(empty_in.value().rows.nulls.count(), 0)
    with assert_raises():
        trainer.push([], [])
    with assert_raises():
        _ = trainer.finish("data", 2, 0, 0)
    var all_null = LanceJsonBTreeTrainer("$")
    all_null.push([None], [0])
    assert_equal(all_null.finish("data", 2, 0, 0).target(), UInt8(4))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
