from akasha.index.flat import SearchResult
from akasha.query.fusion import (
    reciprocal_rank_fusion, rrf_position_score, validate_rrf_weights,
)
from std.math import inf, isfinite
from std.python import Python
from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite


def test_positions_match_unedited_rust_bits() raises:
    var path = Python.import_module("pathlib").Path(
        "tests/fixtures/qdrant-rrf/weighted.json"
    )
    var fixture = Python.import_module("json").loads(path.read_text())
    for sample in fixture["positions"]:
        var score = rrf_position_score(
            Int(py=sample[0]), Int(py=sample[1]),
            bitcast[DType.float32](UInt32(Int(py=sample[2]))),
        )
        assert_equal(bitcast[DType.uint32](score), UInt32(Int(py=sample[3])))


def test_two_rankings_match_rust_fusion_and_length_errors() raises:
    var path = Python.import_module("pathlib").Path(
        "tests/fixtures/qdrant-rrf/weighted.json"
    )
    var fixture = Python.import_module("json").loads(path.read_text())
    for sample in fixture["cases"]:
        if Int(py=sample["branches"].__len__()) != 2:
            continue
        var first = List[SearchResult]()
        var second = List[SearchResult]()
        for id in sample["branches"][0]:
            first.append(SearchResult(Int(py=id), -123))
        for id in sample["branches"][1]:
            second.append(SearchResult(Int(py=id), -456))
        var weights = Optional[List[Float32]]()
        if not Bool(py=sample["weight_bits"] == Python.none()):
            var values = List[Float32]()
            for raw in sample["weight_bits"]:
                values.append(bitcast[DType.float32](UInt32(Int(py=raw))))
            weights = Optional(values^)
        var constant = Int(py=sample["rank_constant"])
        var invalid = Bool(py=sample.__contains__("error"))
        if not invalid:
            for hit in sample["expected"]:
                if not isfinite(bitcast[DType.float32](UInt32(Int(py=hit[1])))):
                    invalid = True
        if invalid:
            with assert_raises():
                _ = reciprocal_rank_fusion(first, second, 100, constant, weights)
            continue
        var actual = reciprocal_rank_fusion(first, second, 100, constant, weights)
        assert_equal(len(actual), Int(py=sample["expected"].__len__()))
        for i in range(len(actual)):
            assert_equal(actual[i].id, Int(py=sample["expected"][i][0]))
            assert_equal(
                bitcast[DType.uint32](actual[i].score),
                UInt32(Int(py=sample["expected"][i][1])),
            )


def test_native_nonfinite_weights_rejected_even_for_empty_rankings() raises:
    for weight in [inf[DType.float32](), -inf[DType.float32](),
                   bitcast[DType.float32](UInt32(0x7FC00000))]:
        var weights: List[Float32] = [weight, 1]
        with assert_raises():
            _ = reciprocal_rank_fusion([], [], 1, weights=Optional(weights.copy()))
    var none = Optional[List[Float32]]()
    validate_rrf_weights(none, 2)
    with assert_raises():
        validate_rrf_weights(Optional(List[Float32]()), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
