from akasha import (
    DocumentField,
    dot_product,
    FlatIndex,
    PayloadValue,
    simd_dot_product,
)
from std.testing import assert_almost_equal, assert_equal, TestSuite


def test_root_package_exports_exact_search_api() raises:
    var index = FlatIndex(1)
    index.add(42, [2.0])
    var query: List[Float32] = [1.0]
    var candidate: List[Float32] = [2.0]
    var results = index.search_dot(query, 1)

    assert_almost_equal(dot_product(query, candidate), 2.0, atol=1.0e-6)
    assert_almost_equal(simd_dot_product(query, candidate), 2.0, atol=1.0e-6)
    assert_equal(results[0].id, 42)


def test_root_package_exports_document_types() raises:
    var field = DocumentField("chunk", PayloadValue.string("hello"))

    assert_equal(field.name, "chunk")
    assert_equal(field.value.as_string(), "hello")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
