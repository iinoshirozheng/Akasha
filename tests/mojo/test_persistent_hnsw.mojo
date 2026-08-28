from akasha import (
    CollectionConfig,
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    MetricKind,
)
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_raises, TestSuite


def _reset(directory: String) raises:
    ensure_directory(directory)
    var names = [
        "collection.bin",
        "collection.bin.tmp",
        "wal.bin",
        "wal.bin.tmp",
        "sparse.wal",
        "sparse.wal.tmp",
        "manifest.bin",
        "manifest.bin.tmp",
        "hnsw.cache",
        "hnsw.cache.tmp",
        "metadata.cache",
        "metadata.cache.tmp",
        "collection.lock",
    ]
    for name in names:
        remove_file_if_exists(directory + "/" + name)
    for sequence in range(100):
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-delta-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-delta-" + String(sequence) + ".bin"
        )


def _dot_config(dimension: Int) -> CollectionConfig:
    var config = CollectionConfig.defaults(dimension)
    config.ann_metric = MetricKind.dot()
    return config^


def _cacheable_l2_config(dimension: Int) -> CollectionConfig:
    var config = CollectionConfig.defaults(dimension)
    config.m0 = config.m
    return config^


def test_small_collection_approximate_api_uses_exact_plan() raises:
    var path = String("/tmp/akasha-phase6-small-plan")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(1, 10):
        collection.upsert(id, [Float32(id)])

    var result = collection.search_dot_approx([1.0], 2, 1)
    assert_equal(result[0].id, 9)
    assert_equal(result[1].id, 8)


def test_large_collection_updates_hnsw_incrementally_after_reopen() raises:
    var path = String("/tmp/akasha-phase6-recovery")
    _reset(path)
    var config = _cacheable_l2_config(1)
    var collection = PersistentCollection.open_with_config(path, config)
    for id in range(1, 81):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    collection.close()

    var reopened = PersistentCollection.open_with_config(path, config)
    var initial = reopened.search_l2_approx([80.0], 3, 80)
    assert_equal(initial[0].id, 80)
    reopened.upsert(80, [1.0])
    reopened.delete(79)
    var build_distances = reopened.hnsw_build_distance_evaluations()
    var updated = reopened.search_l2_approx([80.0], 2, 80)
    assert_equal(updated[0].id, 78)
    assert_equal(updated[1].id, 77)
    assert_equal(
        reopened.hnsw_build_distance_evaluations(), build_distances
    )
    assert_equal(reopened.last_dense_plan_reason(), "ann")


def test_filtered_approximate_search_falls_back_for_selective_match() raises:
    var path = String("/tmp/akasha-phase6-filter-fallback")
    _reset(path)
    var config = _dot_config(1)
    var collection = PersistentCollection.open_with_config(path, config)
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
    assert_equal(collection.last_dense_plan_reason(), "filtered_match_count")


def test_highly_selective_filter_records_selectivity_exact_plan() raises:
    var path = String("/tmp/akasha-phase18-selectivity-fallback")
    _reset(path)
    var config = _dot_config(1)
    var collection = PersistentCollection.open_with_config(path, config)
    for id in range(1, 81):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField("keep", PayloadValue.boolean(id <= 5))
        )
        collection.upsert_document(id, [Float32(id)], fields^)
    var expression = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    var exact = collection.search_dot_where([1.0], 1, expression)
    var approximate = collection.search_dot_approx_where(
        [1.0], 1, 8, expression
    )
    assert_equal(approximate[0].id, exact[0].id)
    assert_equal(collection.last_dense_plan_reason(), "selectivity")


def test_approximate_api_validates_ef_search() raises:
    var path = String("/tmp/akasha-phase6-invalid-ef")
    _reset(path)
    var config = _dot_config(1)
    var collection = PersistentCollection.open_with_config(path, config)
    collection.upsert(1, [1.0])
    with assert_raises():
        _ = collection.search_l2_approx([1.0], 1, 0)


def test_nonselective_filter_uses_hnsw_bitmap_membership() raises:
    var path = String("/tmp/akasha-phase9-hnsw-membership")
    _reset(path)
    var config = _dot_config(1)
    var collection = PersistentCollection.open_with_config(path, config)
    for id in range(1, 81):
        var fields = List[DocumentField]()
        fields.append(DocumentField("keep", PayloadValue.boolean(id % 2 == 0)))
        collection.upsert_document(id, [Float32(id)], fields^)
    var expression = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    var result = collection.search_dot_approx_where([1.0], 3, 80, expression)
    assert_equal(result[0].id, 80)
    assert_equal(result[1].id, 78)
    assert_equal(result[2].id, 76)
    assert_equal(collection.last_dense_plan_reason(), "ann")


def test_hnsw_filter_candidate_shortfall_falls_back_to_exact_bitmap() raises:
    var path = String("/tmp/akasha-phase9-hnsw-shortfall")
    _reset(path)
    var config = _dot_config(1)
    var collection = PersistentCollection.open_with_config(path, config)
    for id in range(1, 81):
        var fields = List[DocumentField]()
        fields.append(DocumentField("keep", PayloadValue.boolean(id <= 40)))
        collection.upsert_document(id, [Float32(id)], fields^)
    var expression = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    var result = collection.search_dot_approx_where([1.0], 2, 8, expression)
    assert_equal(result[0].id, 40)
    assert_equal(result[1].id, 39)
    assert_equal(collection.last_dense_plan_reason(), "ann")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
