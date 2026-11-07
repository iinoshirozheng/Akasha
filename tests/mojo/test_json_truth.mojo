from akasha.query.json_truth import and_truth, or_truth, negate_truth, scalar_predicate
from akasha.index.lance_scalar import LanceScalarKey
from akasha.index.lance_bitmap import LanceBitmapQuery
from std.testing import assert_equal, assert_true, assert_false, TestSuite


def test_three_valued_truth_tables() raises:
    var values: List[Optional[Bool]] = [Optional(False), Optional(True), None]
    # -1 unknown; tables indexed false, true, unknown.
    var conjunction = [0, 0, 0, 0, 1, -1, 0, -1, -1]
    var disjunction = [0, 1, -1, 1, 1, 1, -1, 1, -1]
    for i in range(3):
        for j in range(3):
            var a = and_truth(values[i], values[j])
            var b = or_truth(values[i], values[j])
            assert_equal(Int(a.value()) if a else -1, conjunction[i*3+j])
            assert_equal(Int(b.value()) if b else -1, disjunction[i*3+j])
    assert_false(Bool(negate_truth(None)))
    assert_false(negate_truth(Optional(True)).value())
    assert_true(negate_truth(Optional(False)).value())


def test_null_literals_and_in_residual_semantics() raises:
    var one = LanceScalarKey.integer(1)
    var null = LanceScalarKey.null(2)
    assert_false(Bool(scalar_predicate(one, LanceBitmapQuery.equals(null.copy()))))
    assert_true(scalar_predicate(null, LanceBitmapQuery.is_null()).value())
    assert_false(scalar_predicate(null, LanceBitmapQuery.is_in([])).value())
    var choices = LanceBitmapQuery.is_in([null.copy(), one.copy()])
    assert_true(scalar_predicate(one, choices).value())
    assert_false(Bool(scalar_predicate(LanceScalarKey.integer(2), choices)))
    assert_false(Bool(scalar_predicate(null, choices)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
