from akasha import (
    CollectionConfig,
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    ReadSnapshot,
    SparseElement,
    MetricKind,
)
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    remove_file_if_exists,
)
from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/sparse.wal")
    remove_file_if_exists(directory + "/sparse.wal.tmp")
    for sequence in range(32):
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
            directory + "/sparse-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-delta-" + String(sequence) + ".bin"
        )


def _fields(group: String, chunk: String) raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("group", PayloadValue.string(group)))
    fields.append(DocumentField("chunk", PayloadValue.string(chunk)))
    return fields^


def _old_group_expression() raises -> FilterExpression:
    return FilterExpression.condition(
        FilterCondition.equal("group", PayloadValue.string("old"))
    )


def _compact_with_temporary_snapshot(
    mut collection: PersistentCollection, path: String
) raises:
    var snapshot = collection.snapshot()
    collection.upsert(2, [2.0])
    collection.flush()
    collection.compact()
    assert_true(Bool(snapshot.get(1)))
    assert_true(path_exists(path + "/segment-base-1.bin"))


def test_snapshot_preserves_owned_documents_search_and_filters() raises:
    var path = String("/tmp/akasha-phase11-snapshot-owned")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var first_fields = _fields("old", "first version")
    collection.upsert_document(1, [1.0, 0.0], first_fields^)
    var second_fields = _fields("other", "second point")
    collection.upsert_document(2, [0.0, 1.0], second_fields^)

    var snapshot: ReadSnapshot = collection.snapshot()
    var replacement = _fields("new", "replacement")
    collection.upsert_document(1, [9.0, 0.0], replacement^)
    collection.delete(2)
    collection.upsert(3, [10.0, 0.0])

    assert_equal(snapshot.last_sequence(), UInt64(2))
    var old_document = snapshot.get(1)
    assert_true(Bool(old_document))
    assert_equal(old_document.value().vector[0], Float32(1.0))
    assert_equal(
        old_document.value().get_field("chunk").value().as_string(),
        "first version",
    )
    assert_true(Bool(snapshot.get(2)))
    assert_false(Bool(snapshot.get(3)))

    var exact = snapshot.search_dot([1.0, 0.0], 3)
    assert_equal(len(exact), 2)
    assert_equal(exact[0].id, 1)
    assert_almost_equal(exact[0].score, 1.0, atol=1.0e-6)
    var filtered = snapshot.search_dot_where(
        [1.0, 0.0], 3, _old_group_expression()
    )
    assert_equal(len(filtered), 1)
    assert_equal(filtered[0].id, 1)

    var live_document = collection.get(1)
    assert_equal(live_document.value().vector[0], Float32(9.0))
    assert_false(Bool(collection.get(2)))
    collection.close()


def test_snapshot_preserves_collection_configuration_identity() raises:
    var path = String("/tmp/akasha-task28-snapshot-config")
    _reset(path)
    remove_file_if_exists(path + "/collection.bin")
    remove_file_if_exists(path + "/collection.bin.tmp")
    var config = CollectionConfig.defaults(2)
    config.ann_metric = MetricKind.cosine()
    config.m = 8
    config.m0 = 16
    config.ef_construction = 64
    config.level_seed = UInt64(77)
    var collection = PersistentCollection.open_with_config(path, config)
    var snapshot = collection.snapshot()

    assert_equal(snapshot.collection_config(), config)
    assert_equal(snapshot.config_fingerprint(), config.fingerprint())
    var exposed = snapshot.collection_config()
    exposed.m = 12
    exposed.level_seed = UInt64(99)
    assert_equal(snapshot.collection_config(), config)
    assert_equal(snapshot.config_fingerprint(), config.fingerprint())
    collection.close()


def test_snapshot_survives_later_flush_and_compaction() raises:
    var path = String("/tmp/akasha-phase11-snapshot-compaction")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var fields = _fields("old", "pinned")
    collection.upsert_document(10, [2.0], fields^)
    collection.flush()
    var snapshot = collection.snapshot()

    collection.delete(10)
    collection.upsert(20, [3.0])
    collection.flush()
    collection.compact()

    assert_equal(snapshot.generation(), UInt64(1))
    assert_true(Bool(snapshot.get(10)))
    assert_false(Bool(snapshot.get(20)))
    var results = snapshot.search_l2([2.0], 2)
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 10)
    assert_false(Bool(collection.get(10)))
    collection.close()


def test_snapshot_pin_defers_compaction_reclamation_until_close() raises:
    var path = String("/tmp/akasha-phase11-snapshot-pin")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()
    var snapshot = collection.snapshot()

    collection.upsert(2, [2.0])
    collection.flush()
    collection.compact()

    assert_true(path_exists(path + "/segment-base-1.bin"))
    assert_true(path_exists(path + "/sparse-base-1.bin"))
    assert_true(Bool(snapshot.get(1)))

    snapshot.close()
    _ = collection.maintenance()
    assert_false(path_exists(path + "/segment-base-1.bin"))
    assert_false(path_exists(path + "/sparse-base-1.bin"))
    snapshot.close()
    with assert_raises():
        _ = snapshot.get(1)
    collection.close()


def test_snapshot_raii_releases_generation_pin() raises:
    var path = String("/tmp/akasha-phase11-snapshot-raii")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    collection.flush()

    _compact_with_temporary_snapshot(collection, path)
    _ = collection.maintenance()

    assert_false(path_exists(path + "/segment-base-1.bin"))
    assert_false(path_exists(path + "/sparse-base-1.bin"))
    collection.close()


def test_snapshot_freezes_sparse_hybrid_and_filtered_results() raises:
    var path = String("/tmp/akasha-phase11-snapshot-sparse-hybrid")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var first_fields = _fields("old", "first")
    collection.upsert_document(1, [1.0, 0.0], first_fields^)
    collection.upsert_sparse(1, [SparseElement(7, 2.0)])
    var second_fields = _fields("other", "second")
    collection.upsert_document(2, [0.0, 1.0], second_fields^)
    collection.upsert_sparse(2, [SparseElement(7, 1.0)])
    var snapshot = collection.snapshot()

    collection.upsert_sparse(1, [SparseElement(7, 0.1)])
    collection.delete(2)
    collection.upsert(3, [10.0, 0.0])
    collection.upsert_sparse(3, [SparseElement(7, 10.0)])
    collection.flush()
    collection.compact()

    var sparse = snapshot.search_sparse_dot([SparseElement(7, 1.0)], 3)
    assert_equal(len(sparse), 2)
    assert_equal(sparse[0].id, 1)
    assert_almost_equal(sparse[0].score, 2.0, atol=1.0e-6)
    assert_equal(sparse[1].id, 2)

    var filtered = snapshot.search_sparse_dot_where(
        [SparseElement(7, 1.0)], 3, _old_group_expression()
    )
    assert_equal(len(filtered), 1)
    assert_equal(filtered[0].id, 1)

    var hybrid = snapshot.search_hybrid_dot(
        [1.0, 0.0], [SparseElement(7, 1.0)], 2, 2
    )
    assert_equal(len(hybrid), 2)
    assert_equal(hybrid[0].id, 1)
    assert_equal(hybrid[1].id, 2)

    var hybrid_filtered = snapshot.search_hybrid_dot_where(
        [1.0, 0.0],
        [SparseElement(7, 1.0)],
        2,
        2,
        60,
        _old_group_expression(),
    )
    assert_equal(len(hybrid_filtered), 1)
    assert_equal(hybrid_filtered[0].id, 1)

    var hybrid_l2 = snapshot.search_hybrid_l2(
        [1.0, 0.0], [SparseElement(7, 1.0)], 2, 2
    )
    assert_equal(len(hybrid_l2), 2)
    assert_equal(hybrid_l2[0].id, 1)
    var hybrid_cosine = snapshot.search_hybrid_cosine(
        [1.0, 0.0], [SparseElement(7, 1.0)], 2, 2
    )
    assert_equal(len(hybrid_cosine), 2)
    assert_equal(hybrid_cosine[0].id, 1)
    var hybrid_l2_filtered = snapshot.search_hybrid_l2_where(
        [1.0, 0.0],
        [SparseElement(7, 1.0)],
        2,
        2,
        60,
        _old_group_expression(),
    )
    assert_equal(len(hybrid_l2_filtered), 1)
    assert_equal(hybrid_l2_filtered[0].id, 1)
    var hybrid_cosine_filtered = snapshot.search_hybrid_cosine_where(
        [1.0, 0.0],
        [SparseElement(7, 1.0)],
        2,
        2,
        60,
        _old_group_expression(),
    )
    assert_equal(len(hybrid_cosine_filtered), 1)
    assert_equal(hybrid_cosine_filtered[0].id, 1)

    snapshot.close()
    with assert_raises():
        _ = snapshot.search_sparse_dot([SparseElement(7, 1.0)], 1)
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
