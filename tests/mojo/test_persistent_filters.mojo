from akasha import (
    DocumentField,
    FilterCondition,
    PayloadValue,
    PersistentCollection,
)
from akasha.storage.filesystem import (
    ensure_directory,
    remove_file_if_exists,
)
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    for sequence in range(16):
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin.tmp"
        )


def _fields(category: String, page: Int64) raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("category", PayloadValue.string(category)))
    fields.append(DocumentField("page", PayloadValue.integer(page)))
    return fields^


def test_filtered_dot_search_applies_and_before_topk() raises:
    var path = String("/tmp/akasha-phase4-filter-dot")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var first = _fields("keep", 9)
    var second = _fields("drop", 9)
    var third = _fields("keep", 3)
    collection.upsert_document(1, [3.0, 0.0], first^)
    collection.upsert_document(2, [4.0, 0.0], second^)
    collection.upsert_document(3, [1.0, 0.0], third^)

    var conditions = List[FilterCondition]()
    conditions.append(
        FilterCondition.equal("category", PayloadValue.string("keep"))
    )
    conditions.append(
        FilterCondition.greater_or_equal("page", PayloadValue.integer(3))
    )
    var query: List[Float32] = [1.0, 0.0]
    var results = collection.search_dot_filtered(query, 2, conditions)

    assert_equal(len(results), 2)
    assert_equal(results[0].id, 1)
    assert_equal(results[1].id, 3)


def test_filtered_l2_and_cosine_preserve_metric_ordering_and_ties() raises:
    var path = String("/tmp/akasha-phase4-filter-metrics")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var first = _fields("keep", 1)
    var second = _fields("keep", 1)
    var third = _fields("drop", 1)
    collection.upsert_document(5, [1.0, 0.0], first^)
    collection.upsert_document(2, [1.0, 0.0], second^)
    collection.upsert_document(1, [0.0, 1.0], third^)

    var conditions = List[FilterCondition]()
    conditions.append(
        FilterCondition.equal("category", PayloadValue.string("keep"))
    )
    var query: List[Float32] = [1.0, 0.0]
    var l2 = collection.search_l2_filtered(query, 2, conditions)
    var cosine = collection.search_cosine_filtered(query, 2, conditions)

    assert_equal(l2[0].id, 2)
    assert_equal(l2[1].id, 5)
    assert_equal(cosine[0].id, 2)
    assert_equal(cosine[1].id, 5)


def test_empty_conditions_match_unfiltered_search_and_no_match_is_empty() raises:
    var path = String("/tmp/akasha-phase4-filter-empty")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [2.0])
    collection.upsert(2, [1.0])
    var query: List[Float32] = [1.0]

    var empty = List[FilterCondition]()
    var unfiltered = collection.search_dot(query, 2)
    var filtered = collection.search_dot_filtered(query, 2, empty)
    assert_equal(filtered[0].id, unfiltered[0].id)
    assert_equal(filtered[1].id, unfiltered[1].id)

    var missing = List[FilterCondition]()
    missing.append(
        FilterCondition.equal("category", PayloadValue.string("missing"))
    )
    var none = collection.search_dot_filtered(query, 2, missing)
    assert_equal(len(none), 0)


def test_cosine_filter_rejects_zero_norm_vector_before_scoring() raises:
    var path = String("/tmp/akasha-phase4-filter-prefilter")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var rejected = _fields("drop", 1)
    var accepted = _fields("keep", 1)
    collection.upsert_document(1, [0.0, 0.0], rejected^)
    collection.upsert_document(2, [1.0, 0.0], accepted^)
    var query: List[Float32] = [1.0, 0.0]

    with assert_raises():
        _ = collection.search_cosine(query, 1)

    var conditions = List[FilterCondition]()
    conditions.append(
        FilterCondition.equal("category", PayloadValue.string("keep"))
    )
    var results = collection.search_cosine_filtered(query, 1, conditions)
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 2)


def test_filtered_search_revalidates_mutated_conditions() raises:
    var path = String("/tmp/akasha-phase4-filter-validation")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    var condition = FilterCondition.equal(
        "category", PayloadValue.string("keep")
    )
    condition.name = ""
    var conditions = List[FilterCondition]()
    conditions.append(condition^)
    var query: List[Float32] = [1.0]

    with assert_raises():
        _ = collection.search_dot_filtered(query, 1, conditions)


def test_filtered_search_survives_wal_only_reopen_and_resolves_payload() raises:
    var path = String("/tmp/akasha-phase4-filter-wal-reopen")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var keep = _fields("keep", 9)
    var drop = _fields("drop", 9)
    collection.upsert_document(10, [2.0, 0.0], keep^)
    collection.upsert_document(20, [3.0, 0.0], drop^)

    var reopened = PersistentCollection.open(path, 2)
    var conditions = List[FilterCondition]()
    conditions.append(
        FilterCondition.equal("category", PayloadValue.string("keep"))
    )
    var query: List[Float32] = [1.0, 0.0]
    var results = reopened.search_dot_filtered(query, 1, conditions)
    var document = reopened.get(results[0].id)

    assert_equal(results[0].id, 10)
    assert_true(Bool(document))
    assert_equal(
        document.value().get_field("category").value().as_string(), "keep"
    )


def test_filtered_search_survives_snapshot_reopen() raises:
    var path = String("/tmp/akasha-phase4-filter-snapshot-reopen")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var lower = _fields("keep", 2)
    var higher = _fields("keep", 8)
    collection.upsert_document(1, [3.0, 0.0], lower^)
    collection.upsert_document(2, [1.0, 0.0], higher^)
    collection.flush()

    var reopened = PersistentCollection.open(path, 2)
    var conditions = List[FilterCondition]()
    conditions.append(
        FilterCondition.greater_than("page", PayloadValue.integer(5))
    )
    var query: List[Float32] = [1.0, 0.0]
    var results = reopened.search_dot_filtered(query, 2, conditions)

    assert_equal(len(results), 1)
    assert_equal(results[0].id, 2)


def test_vector_replacement_and_delete_remove_filter_candidates() raises:
    var path = String("/tmp/akasha-phase4-filter-mutations")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var replaced = _fields("keep", 1)
    var deleted = _fields("keep", 1)
    collection.upsert_document(1, [3.0], replaced^)
    collection.upsert_document(2, [2.0], deleted^)
    collection.upsert(1, [3.0])
    collection.delete(2)

    var conditions = List[FilterCondition]()
    conditions.append(
        FilterCondition.equal("category", PayloadValue.string("keep"))
    )
    var query: List[Float32] = [1.0]
    var results = collection.search_dot_filtered(query, 2, conditions)

    assert_equal(len(results), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
