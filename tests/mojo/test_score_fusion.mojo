from akasha.query.score_fusion import distribution_normalize
from std.math import abs, inf
from std.python import Python
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def test_matches_pinned_unedited_qdrant_normalization() raises:
    var json = Python.import_module("json")
    var path = Python.import_module("pathlib").Path(
        "tests/fixtures/qdrant-dbsf/normalization.json"
    )
    var fixture = json.loads(path.read_text())
    for sample in fixture["cases"]:
        var scores = List[Float32]()
        for item in sample["input"]:
            scores.append(Float32(py=item))
        var actual = distribution_normalize(scores)
        assert_equal(len(actual), Int(py=sample["output"].__len__()))
        for i in range(len(actual)):
            var expected = Float32(py=sample["output"][i])
            assert_true(abs(actual[i] - expected) <= Float32(0.00001))


def test_empty_singleton_constants_and_no_clamping() raises:
    assert_equal(len(distribution_normalize([])), 0)
    assert_equal(distribution_normalize([Float32(99)])[0], Float32(0.5))
    var equal = distribution_normalize([Float32(8), Float32(8)])
    assert_equal(equal[0], Float32(0.5))
    assert_equal(equal[1], Float32(0.5))
    var outlier = List[Float32]()
    for _ in range(63):
        outlier.append(0)
    outlier.append(1000)
    assert_true(distribution_normalize(outlier)[63] > Float32(1))


def test_nonfinite_and_overflow_are_rejected() raises:
    with assert_raises():
        _ = distribution_normalize([inf[DType.float32]()])
    with assert_raises():
        _ = distribution_normalize([Float32(-3e38), Float32(3e38)])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
