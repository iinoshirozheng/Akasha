from akasha.index.quantization import Sq8Codebook, Sq8Index
from std.math import abs, inf
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def test_sq8_codebook_is_deterministic_and_bounds_reconstruction() raises:
    var vectors = List[List[Float32]]()
    vectors.append([0.0, 5.0, -2.0])
    vectors.append([10.0, 5.0, 2.0])
    vectors.append([4.0, 5.0, 0.5])

    var lhs = Sq8Codebook.train(vectors)
    var rhs = Sq8Codebook.train(vectors)
    assert_equal(lhs.version(), UInt32(1))
    assert_equal(lhs.dimension(), 3)
    assert_equal(lhs.minimum(0), rhs.minimum(0))
    assert_equal(lhs.scale(2), rhs.scale(2))

    var code = lhs.encode([4.0, 5.0, 0.5])
    var decoded = lhs.decode(code)
    assert_equal(code[1], UInt8(0))
    assert_equal(decoded[1], Float32(5.0))
    assert_true(abs(decoded[0] - 4.0) <= lhs.scale(0))
    assert_true(abs(decoded[2] - 0.5) <= lhs.scale(2))


def test_sq8_index_searches_all_metrics_with_stable_ties() raises:
    var ids: List[Int] = [1, 2, 3, 4]
    var vectors = List[List[Float32]]()
    vectors.append([1.0, 0.0])
    vectors.append([2.0, 0.0])
    vectors.append([2.0, 0.0])
    vectors.append([0.0, 1.0])
    var index = Sq8Index.build(ids, vectors)

    var dot = index.search_dot([1.0, 0.0], 3)
    var l2 = index.search_l2([1.8, 0.0], 2)
    var cosine = index.search_cosine([1.0, 0.0], 3)
    assert_equal(dot[0].id, 2)
    assert_equal(dot[1].id, 3)
    assert_equal(l2[0].id, 2)
    assert_equal(l2[1].id, 3)
    assert_equal(cosine[0].id, 1)
    assert_equal(cosine[1].id, 2)
    assert_equal(cosine[2].id, 3)
    assert_equal(index.encoded_bytes(), 8)
    assert_true(index.estimated_bytes() < len(vectors) * 2 * 4 + 64)


def test_sq8_rejects_invalid_training_and_queries() raises:
    with assert_raises():
        _ = Sq8Codebook.train(List[List[Float32]]())

    var malformed = List[List[Float32]]()
    malformed.append([1.0, 2.0])
    malformed.append([1.0])
    with assert_raises():
        _ = Sq8Codebook.train(malformed)

    var non_finite = List[List[Float32]]()
    non_finite.append([inf[DType.float32]()])
    with assert_raises():
        _ = Sq8Codebook.train(non_finite)

    var ids: List[Int] = [1]
    var vectors = List[List[Float32]]()
    vectors.append([1.0, 2.0])
    var index = Sq8Index.build(ids, vectors)
    with assert_raises():
        _ = index.search_dot([1.0], 1)
    with assert_raises():
        _ = index.search_l2([1.0, 2.0], 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
