from akasha import (
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
)
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_raises, TestSuite


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    for sequence in range(100):
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin"
        )


def test_small_collection_approximate_api_uses_exact_plan() raises:
    var path = String("/tmp/akasha-phase6-small-plan")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(1, 10):
        collection.upsert(id, [Float32(id)])

    var result = collection.search_dot_approx([1.0], 2, 1)
    assert_equal(result[0].id, 9)
    assert_equal(result[1].id, 8)


def test_large_collection_rebuilds_hnsw_on_reopen_replace_and_delete() raises:
    var path = String("/tmp/akasha-phase6-recovery")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(1, 81):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    var initial = reopened.search_dot_approx([1.0], 3, 80)
    assert_equal(initial[0].id, 80)
    reopened.upsert(80, [1.0])
    reopened.delete(79)
    var updated = reopened.search_dot_approx([1.0], 2, 80)
    assert_equal(updated[0].id, 78)
    assert_equal(updated[1].id, 77)


def test_filtered_approximate_search_falls_back_for_selective_match() raises:
    var path = String("/tmp/akasha-phase6-filter-fallback")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(1, 81):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField("keep", PayloadValue.boolean(id == 1 or id == 2))
        )
        collection.upsert_document(id, [Float32(id)], fields^)

    var expression = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    var result = collection.search_dot_approx_where([1.0], 2, 4, expression)
    assert_equal(len(result), 2)
    assert_equal(result[0].id, 2)
    assert_equal(result[1].id, 1)


def test_approximate_api_validates_ef_search() raises:
    var path = String("/tmp/akasha-phase6-invalid-ef")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    with assert_raises():
        _ = collection.search_l2_approx([1.0], 1, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
