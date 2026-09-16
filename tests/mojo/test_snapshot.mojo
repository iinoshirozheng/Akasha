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
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable
from akasha.storage.read_generation import ReadGenerationCache
from akasha.index.sparse import SparseIndex
from std.memory import ArcPointer
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

    var exported = snapshot.documents()
    assert_equal(len(exported), 2)
    assert_equal(exported[0].id, 1)
    assert_equal(exported[1].id, 2)
    assert_equal(exported[0].fields[1].value.as_string(), "first version")
    exported[0].vector[0] = 100.0
    exported[0].fields[0].name = "changed"
    assert_equal(snapshot.get(1).value().vector[0], Float32(1.0))
    assert_equal(snapshot.get(1).value().fields[0].name, "group")

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



def test_same_view_shares_root_and_close_releases_only_its_owner() raises:
    var path = String("/tmp/akasha-47-shared-root")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var fields = _fields("old", "shared")
    collection.upsert_document(1, [2.0], fields^)
    collection.upsert_sparse(1, [SparseElement(7, 3.0)])
    var first = collection.snapshot()
    var second = collection.snapshot()
    assert_true(first._root.value() is second._root.value())
    assert_equal(first._root.value().count(), UInt64(3))
    assert_equal(collection._read_generations[].revision, UInt64(1))
    assert_equal(collection._pins[].active_count(), 1)
    assert_equal(
        Int(first._base().memtable.entry_ref_at(0).values.unsafe_ptr()),
        Int(second._base().memtable.entry_ref_at(0).values.unsafe_ptr()),
    )
    var document = first.get(1)
    document.value().vector[0] = 99.0
    document.value().fields[0].name = "changed"
    assert_equal(second.get(1).value().vector[0], Float32(2.0))
    assert_equal(second.get(1).value().fields[0].name, "group")
    first.close()
    first.close()
    assert_false(Bool(first._root))
    assert_equal(second._root.value().count(), UInt64(2))
    with assert_raises():
        _ = first.search_dot_parallel([1.0], 1)
    collection.close()
    assert_equal(second._root.value().count(), UInt64(1))
    assert_equal(second.search_dot([1.0], 1)[0].score, Float32(2.0))
    assert_equal(second.search_sparse_dot([SparseElement(7, 1.0)], 1)[0].score, Float32(3.0))
    assert_equal(collection._pins[].active_count(), 1)
    second.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_shared_roots_isolate_replace_sparse_delete_and_reinsert() raises:
    var path = String("/tmp/akasha-47-root-revisions")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var fields = _fields("old", "original")
    collection.upsert_document(-1, [1.0], fields^)
    collection.upsert_sparse(-1, [SparseElement(7, 2.0)])
    var original = collection.snapshot()
    var sibling = collection.snapshot()
    var replacement = _fields("new", "replacement")
    collection.upsert_document(-1, [9.0], replacement^)
    var replaced = collection.snapshot()
    assert_equal(original.generation(), replaced.generation())
    assert_true(original.last_sequence() < replaced.last_sequence())
    assert_false(original._root.value() is replaced._root.value())
    collection.upsert_sparse(-1, [SparseElement(7, 8.0)])
    var sparse_updated = collection.snapshot()
    assert_false(replaced._root.value() is sparse_updated._root.value())
    collection.delete(-1)
    var deleted = collection.snapshot()
    collection.upsert(-1, [4.0])
    var reinserted = collection.snapshot()
    collection.close()
    original.close()
    assert_equal(sibling.get(-1).value().vector[0], Float32(1.0))
    assert_equal(sibling.get(-1).value().get_field("chunk").value().as_string(), "original")
    assert_equal(sibling.search_dot_where([1.0], 1, _old_group_expression())[0].id, -1)
    assert_equal(sibling.search_hybrid_dot([1.0], [SparseElement(7, 1.0)], 1, 1)[0].id, -1)
    assert_equal(replaced.get(-1).value().vector[0], Float32(9.0))
    assert_equal(replaced.search_sparse_dot([SparseElement(7, 1.0)], 1)[0].score, Float32(2.0))
    assert_equal(sparse_updated.search_sparse_dot([SparseElement(7, 1.0)], 1)[0].score, Float32(8.0))
    assert_false(Bool(deleted.get(-1)))
    assert_equal(len(deleted.search_sparse_dot([SparseElement(7, 1.0)], 1)), 0)
    assert_equal(reinserted.get(-1).value().vector[0], Float32(4.0))
    assert_equal(len(reinserted.get(-1).value().fields), 0)
    assert_equal(len(reinserted.search_sparse_dot([SparseElement(7, 1.0)], 1)), 0)
    sibling.close()
    replaced.close()
    sparse_updated.close()
    deleted.close()
    reinserted.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_layout_publication_changes_root_without_changing_sequence() raises:
    var path = String("/tmp/akasha-47-root-layout")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    var unflushed = collection.snapshot()
    collection.flush()
    var flushed = collection.snapshot()
    assert_equal(unflushed.last_sequence(), flushed.last_sequence())
    assert_true(unflushed.generation() < flushed.generation())
    assert_false(unflushed._root.value() is flushed._root.value())
    collection.flush()
    var unchanged = collection.snapshot()
    assert_true(flushed._root.value() is unchanged._root.value())
    collection.upsert(2, [2.0])
    collection.flush()
    var before_compact = collection.snapshot()
    collection.compact()
    var after_compact = collection.snapshot()
    assert_equal(before_compact.last_sequence(), after_compact.last_sequence())
    assert_true(before_compact.generation() < after_compact.generation())
    assert_false(before_compact._root.value() is after_compact._root.value())
    assert_equal(len(before_compact.documents()), 2)
    collection.close()
    # Reopening creates an independent publisher even at equal G and S.
    var reopened = PersistentCollection.open(path, 1)
    var reopened_view = reopened.snapshot()
    assert_equal(after_compact.generation(), reopened_view.generation())
    assert_equal(after_compact.last_sequence(), reopened_view.last_sequence())
    assert_false(after_compact._root.value() is reopened_view._root.value())
    reopened.close()


def _raii_sibling(collection: PersistentCollection, expected: ReadSnapshot) raises:
    var transient = collection.snapshot()
    assert_true(transient._root.value() is expected._root.value())
    assert_equal(transient.get(1).value().vector[0], Float32(1.0))


def test_shared_root_raii_and_failed_capture_do_not_leak_pins() raises:
    var path = String("/tmp/akasha-47-root-raii")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    collection.upsert(1, [1.0])
    var snapshot = collection.snapshot()
    _raii_sibling(collection, snapshot)
    assert_equal(snapshot._root.value().count(), UInt64(2))
    collection.close()
    snapshot.close()
    assert_equal(collection._pins[].active_count(), 0)

    var cache = ReadGenerationCache()
    var pins = ArcPointer(GenerationPinRegistry())
    var table = MemTable(1)
    table.apply_upsert(1, 1, [1.0])
    var sparse = SparseIndex()
    var config = CollectionConfig.defaults(1)
    var root = cache.acquire(config, 0, 1, table, sparse, pins)
    with assert_raises():
        _ = cache.acquire(CollectionConfig.defaults(2), 0, 2, table, sparse, pins)
    with assert_raises():
        _ = ReadSnapshot.capture(config, 0, 0, table, sparse, pins)
    # Inject a malformed internal row to exercise failure during base copying,
    # after the identity checks, without a runtime fault-injection interface.
    table._entries[0].fields.append(DocumentField("x", PayloadValue.integer(1)))
    table._entries[0].fields.append(DocumentField("x", PayloadValue.integer(2)))
    with assert_raises():
        _ = cache.acquire(config, 0, 2, table, sparse, pins)
    assert_true(cache.root.value() is root)
    assert_equal(cache.revision, UInt64(1))
    assert_equal(pins[].active_count(), 1)
    _ = root^
    cache.invalidate()
    assert_equal(pins[].active_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
