from akasha.index.lance_json_stream import LanceJsonBitmapTrainer
from akasha.index.lance_scalar import LanceScalarKey
from akasha.document.jsonb_reader import parse_jsonb
from akasha.query.control import CancellationToken, QueryControl
from std.testing import assert_true, assert_false, assert_equal, assert_raises, TestSuite


def test_typed_comparisons_preserve_bounds_and_unknowns() raises:
    var trainer = LanceJsonBitmapTrainer("v")
    trainer.push([Optional(parse_jsonb("{v:1}")), Optional(parse_jsonb("{v:2}")), Optional(parse_jsonb("{v:3}")), None], [1, 2, 3, 4])
    var index = trainer.finish()
    var operators: List[String] = ["eq", "ne", "lt", "le", "gt", "ge"]
    for op in operators:
        var result = index.try_compare("json_get_int", Optional(String("v")), op, LanceScalarKey.integer(2))
        assert_true(Bool(result))
        for value in range(1, 4):
            var expected = value == 2 if op == "eq" else value != 2 if op == "ne" else value < 2 if op == "lt" else value <= 2 if op == "le" else value > 2 if op == "gt" else value >= 2
            assert_equal(result.value().selected(UInt64(value)), expected)
        assert_false(result.value().selected(4))
        assert_true(result.value().rows.nulls.contains(4))


def test_unbound_comparisons_remain_residual_and_cancel() raises:
    var trainer = LanceJsonBitmapTrainer("v")
    trainer.push([Optional(parse_jsonb("{v:2}"))], [1])
    var index = trainer.finish()
    assert_false(Bool(index.try_compare("json_get_int", Optional(String("v")), "eq", LanceScalarKey.null(2))))
    assert_false(Bool(index.try_compare("json_get_int", Optional(String("v")), "eq", LanceScalarKey.text("2"))))
    assert_false(Bool(index.try_compare("json_get_int", Optional(String("v")), "contains", LanceScalarKey.integer(2))))
    assert_false(Bool(index.try_compare("json_get_int", Optional(String("$.v")), "eq", LanceScalarKey.integer(2))))
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=100)
    token.cancel()
    with assert_raises():
        _ = index.try_compare("json_get_int", Optional(String("v")), "contains", LanceScalarKey.integer(2), control=Optional(control.copy()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
