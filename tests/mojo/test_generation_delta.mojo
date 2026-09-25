from akasha import (
    BatchMutation,
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    ReadSnapshot,
    SparseElement,
)
from akasha.common.config import CollectionConfig
from akasha.compute.gpu.planner import GpuExecutionOptions
from akasha.index.flat import SearchResult
from akasha.query.control import CancellationToken, QueryControl
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from akasha.storage.generation_pins import GenerationPinRegistry
from akasha.storage.memtable import MemTable
from akasha.storage.read_generation import (
    HEAD_MAX_BYTES,
    HEAD_MAX_POINTS,
    MAX_SEALED_RUNS,
    ReadGenerationCache,
)
from std.memory import ArcPointer
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(path: String) raises:
    ensure_directory(path)
    remove_file_if_exists(path + "/manifest.bin")
    remove_file_if_exists(path + "/manifest.bin.tmp")
    remove_file_if_exists(path + "/wal.bin")
    remove_file_if_exists(path + "/wal.bin.tmp")
    remove_file_if_exists(path + "/sparse.wal")
    remove_file_if_exists(path + "/sparse.wal.tmp")


def _vector(id: Int, revision: Int) -> List[Float32]:
    return [
        Float32(id % 17) + Float32(revision),
        1.0,
        Float32(id % 5) - Float32(revision),
        Float32(id % 3) + 0.5,
    ]


def _fields(id: Int, revision: Int) raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(
        DocumentField(
            "group", PayloadValue.string("even" if id % 2 == 0 else "odd")
        )
    )
    fields.append(
        DocumentField("revision", PayloadValue.integer(Int64(revision)))
    )
    return fields^


def _write(
    mut collection: PersistentCollection, first: Int, count: Int, revision: Int
) raises:
    """Upsert IDs [first, first + count) as one atomic envelope."""
    var mutations = List[BatchMutation](capacity=count)
    for id in range(first, first + count):
        mutations.append(
            BatchMutation.document_upsert(
                id, _vector(id, revision), _fields(id, revision)
            )
        )
    _ = collection.apply_batch(mutations)


def _even() raises -> FilterExpression:
    return FilterExpression.condition(
        FilterCondition.equal("group", PayloadValue.string("even"))
    )


def _flat(
    snapshot: ReadSnapshot, collection: PersistentCollection
) raises -> ReadSnapshot:
    """A reference view with one unshadowed base built from writer state."""
    var cache = ReadGenerationCache()
    return ReadSnapshot(
        cache.acquire(
            snapshot.collection_config(),
            snapshot.generation(),
            snapshot.last_sequence(),
            collection._memtable,
            collection._pins,
        )
    )


def _same(actual: List[SearchResult], expected: List[SearchResult]) raises:
    assert_equal(len(actual), len(expected))
    for index in range(len(expected)):
        assert_equal(actual[index].id, expected[index].id)
        assert_equal(actual[index].score, expected[index].score)


def _same_batch(
    actual: List[List[SearchResult]], expected: List[List[SearchResult]]
) raises:
    assert_equal(len(actual), len(expected))
    for index in range(len(expected)):
        _same(actual[index], expected[index])


def _assert_equivalent(layered: ReadSnapshot, flat: ReadSnapshot) raises:
    """Every read path must match an unshadowed view of the same state."""
    var query: List[Float32] = [1.0, 0.5, -0.25, 2.0]
    var queries = List[List[Float32]]()
    for index in range(5):
        queries.append([Float32(index) - 2.0, 1.0, 0.5, Float32(index)])
    var expressions = List[FilterExpression]()
    for _ in range(5):
        expressions.append(_even())
    _same(layered.search_dot(query, 10), flat.search_dot(query, 10))
    _same(layered.search_l2(query, 10), flat.search_l2(query, 10))
    _same(layered.search_cosine(query, 10), flat.search_cosine(query, 10))
    _same(
        layered.search_dot_where(query, 10, _even()),
        flat.search_dot_where(query, 10, _even()),
    )
    _same(
        layered.search_l2_parallel(query, 10, num_workers=3),
        flat.search_l2_parallel(query, 10, num_workers=3),
    )
    _same(
        layered.search_dot_where_parallel(query, 10, _even(), num_workers=3),
        flat.search_dot_where_parallel(query, 10, _even(), num_workers=3),
    )
    _same_batch(
        layered.search_dot_batch(queries, 7, num_workers=2),
        flat.search_dot_batch(queries, 7, num_workers=2),
    )
    _same_batch(
        layered.search_l2_where_batch(queries, expressions, 7, num_workers=2),
        flat.search_l2_where_batch(queries, expressions, 7, num_workers=2),
    )
    var token = CancellationToken()
    var control = QueryControl(token, max_candidates=1_000_000)
    _same(
        layered.search_dot_controlled(query, 10, control),
        flat.search_dot_controlled(query, 10, control),
    )
    _same(
        layered.search_sq8_dot(query, 5, rerank_k=20),
        flat.search_sq8_dot(query, 5, rerank_k=20),
    )
    var options = GpuExecutionOptions(enabled=True, min_work_items=1)
    _same_batch(
        layered.search_device_dot_batch[use_accelerator=False](
            queries, 7, options
        ).results,
        flat.search_device_dot_batch[use_accelerator=False](
            queries, 7, options
        ).results,
    )
    _same_batch(
        layered.search_device_l2_where_batch[use_accelerator=False](
            queries, expressions, 7, options
        ).results,
        flat.search_device_l2_where_batch[use_accelerator=False](
            queries, expressions, 7, options
        ).results,
    )
    var sparse: List[SparseElement] = [SparseElement(7, 1.0)]
    _same(
        layered.search_sparse_dot_where(sparse, 5, _even()),
        flat.search_sparse_dot_where(sparse, 5, _even()),
    )
    _same(
        layered.search_hybrid_dot(query, sparse, 5, 20),
        flat.search_hybrid_dot(query, sparse, 5, 20),
    )
    var documents = layered.documents()
    var expected = flat.documents()
    assert_equal(len(documents), len(expected))
    for index in range(len(expected)):
        assert_equal(documents[index].id, expected[index].id)
        assert_equal(documents[index].sequence, expected[index].sequence)
        assert_equal(documents[index].vector[0], expected[index].vector[0])
        assert_equal(len(documents[index].fields), len(expected[index].fields))


def _dense_address(snapshot: ReadSnapshot, id: Int) raises -> Int:
    var location = snapshot._slot[].root.value()[].find(id)
    return (
        snapshot._slot[]
        .root.value()[]
        .run(location[0])
        .memtable.entry_ref_at(location[1])
        .dense_address()
    )


def _copied_dense_bytes(
    snapshot: ReadSnapshot, collection: PersistentCollection
) raises -> Int:
    """Audit by owner identity: bytes of visible rows not shared with writer."""
    var copied = 0
    for location in snapshot._slot[].root.value()[].id_ordered_locations():
        ref entry = (
            snapshot._slot[]
            .root.value()[]
            .run(location[0])
            .memtable.entry_ref_at(location[1])
        )
        ref live = collection._memtable.entry_ref_at(
            collection._memtable.ordinal_for(entry.id)
        )
        if entry.dense_address() != live.dense_address():
            copied += entry.dense_bytes()
    return copied


def test_capture_copies_no_base_dense_bytes() raises:
    var path = String("/tmp/akasha-48-capture-cost")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    for chunk in range(4):
        _write(collection, chunk * 1024, 1024, 0)
    var first = collection.snapshot()
    ref stats = collection._read_generations[].stats
    assert_equal(stats.base_builds, 1)
    assert_equal(_copied_dense_bytes(first, collection), 0)
    for delta in [0, 16, 1024]:
        if delta == 16:
            for id in range(delta):
                collection.upsert_document(id, _vector(id, 1), _fields(id, 1))
        elif delta > 0:
            _write(collection, 0, delta, 2)
        var copies = stats.descriptor_copies
        var payload = stats.payload_bytes
        var head = collection._read_generations[].head_count()
        var snapshot = collection.snapshot()
        if delta == 0:
            assert_true(
                snapshot._slot[].root.value() is first._slot[].root.value()
            )
        # Capture copies only the head's descriptors; fields stay shared.
        assert_equal(stats.descriptor_copies - copies, head)
        assert_true(head <= delta)
        assert_equal(stats.payload_bytes, payload)
        assert_equal(stats.base_builds, 1)
        assert_true(
            snapshot._slot[].root.value()[].layers[0].run
            is first._slot[].root.value()[].layers[0].run
        )
        assert_equal(_copied_dense_bytes(snapshot, collection), 0)
        for id in range(delta, 4096, 61):
            assert_equal(
                _dense_address(snapshot, id), _dense_address(first, id)
            )
        assert_equal(snapshot._slot[].root.value()[].visible_count, 4096)
        _assert_equivalent(snapshot, _flat(snapshot, collection))
    assert_equal(stats.rollovers, 1)
    assert_equal(first.get(0).value().vector[0], Float32(0.0))
    collection.close()


def test_rollover_oversized_record_and_consolidation() raises:
    var table = MemTable(4)
    var pins = ArcPointer(GenerationPinRegistry())
    var config = CollectionConfig.defaults(4)
    var cache = ReadGenerationCache()
    var sequence = UInt64(0)
    for id in range(10):
        sequence += 1
        table.apply_upsert(id, sequence, _vector(id, 0))
    var original = cache.acquire(config, 0, sequence, table, pins)
    var original_base = original[].layers[0].run.copy()

    sequence += 1
    table.apply_upsert(100, sequence, _vector(100, 0))
    cache.record(table, [100], sequence)
    var blob = List[DocumentField]()
    blob.append(
        DocumentField(
            "blob", PayloadValue.string("x" * (HEAD_MAX_BYTES + 1024))
        )
    )
    sequence += 1
    table.apply_document_upsert(101, sequence, _vector(101, 0), blob^)
    cache.record(table, [101], sequence)
    # The legal oversized record seals the small head first, then itself.
    assert_equal(cache.stats.rollovers, 2)
    assert_equal(cache.sealed_count(), 2)
    assert_equal(cache.head_count(), 0)
    var sealed = cache.acquire(config, 0, sequence, table, pins)
    assert_equal(sealed[].layer_count(), 3)
    assert_equal(sealed[].run(1).memtable.slot_count(), 1)
    assert_equal(sealed[].run(1).memtable.id_at(0), 100)
    assert_equal(sealed[].run(2).memtable.slot_count(), 1)
    assert_equal(sealed[].run(2).memtable.id_at(0), 101)
    assert_true(sealed[].layers[0].run is original_base)

    var id = 1000
    while cache.stats.consolidations == 0:
        sequence += 1
        table.apply_upsert(id % 3000, sequence, _vector(id, 1))
        cache.record(table, [id % 3000], sequence)
        assert_true(cache.sealed_count() < MAX_SEALED_RUNS)
        assert_true(cache.head_count() < HEAD_MAX_POINTS)
        id += 1
    assert_equal(cache.sealed_count(), 0)
    assert_equal(cache.stats.base_builds, 2)
    var merged = cache.acquire(config, 0, sequence, table, pins)
    assert_false(merged[].layers[0].run is original_base)
    assert_equal(merged[].visible_count, table.live_count())
    # Consolidation shares dense owners with the writer table.
    for check in [0, 100, 101, 1500]:
        var location = merged[].find(check)
        assert_equal(
            merged[]
            .run(location[0])
            .memtable.entry_ref_at(location[1])
            .dense_address(),
            table.entry_ref_at(table.ordinal_for(check)).dense_address(),
        )
    # Old roots keep their chains after rollover and consolidation.
    assert_equal(original[].visible_count, 10)
    assert_equal(original[].find(100)[0], -1)
    assert_equal(sealed[].visible_count, 12)
    assert_equal(
        sealed[]
        .run(2)
        .memtable.entry_ref_at(0)
        .fields()[0]
        .value.as_string()
        .byte_length(),
        HEAD_MAX_BYTES + 1024,
    )
    _ = original^
    _ = sealed^
    _ = merged^
    cache.reset()
    assert_equal(pins[].active_count(), 0)


def test_old_snapshot_survives_mutation_rollover_consolidation_and_close() raises:
    var path = String("/tmp/akasha-48-old-root")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _write(collection, 0, 64, 0)
    collection.upsert_sparse(4, [SparseElement(7, 3.0)])
    var old = collection.snapshot()
    var query: List[Float32] = [1.0, 0.5, -0.25, 2.0]
    var old_dot = old.search_dot(query, 10)
    var old_where = old.search_l2_where(query, 10, _even())
    var old_documents = old.documents()

    collection.upsert_document(1, _vector(1, 9), _fields(1, 9))
    collection.delete(2)
    collection.upsert_sparse(4, [SparseElement(7, 5.0)])
    var deleted = collection.snapshot()
    collection.upsert(2, _vector(2, 7))
    for chunk in range(MAX_SEALED_RUNS + 1):
        _write(collection, 1000 + chunk * 1024, 1024, chunk)
    ref stats = collection._read_generations[].stats
    assert_true(stats.rollovers >= MAX_SEALED_RUNS)
    assert_equal(stats.consolidations, 1)
    var latest = collection.snapshot()
    _assert_equivalent(latest, _flat(latest, collection))
    collection.close()

    _same(old.search_dot(query, 10), old_dot)
    _same(old.search_l2_where(query, 10, _even()), old_where)
    var documents = old.documents()
    assert_equal(len(documents), len(old_documents))
    assert_equal(len(documents), 64)
    assert_equal(old.get(1).value().vector[0], _vector(1, 0)[0])
    assert_equal(old.get(2).value().vector[0], _vector(2, 0)[0])
    assert_equal(
        old.search_sparse_dot([SparseElement(7, 1.0)], 1)[0].score, Float32(3.0)
    )
    assert_false(Bool(deleted.get(2)))
    assert_equal(deleted.get(1).value().vector[0], _vector(1, 9)[0])
    assert_equal(
        deleted.search_sparse_dot([SparseElement(7, 1.0)], 1)[0].score,
        Float32(5.0),
    )
    assert_equal(latest.get(2).value().vector[0], _vector(2, 7)[0])
    assert_equal(len(latest.get(2).value().fields), 0)
    assert_equal(len(latest.documents()), 64 + (MAX_SEALED_RUNS + 1) * 1024)
    old.close()
    deleted.close()
    latest.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_sparse_only_update_shares_dense_and_owned_get_is_independent() raises:
    var path = String("/tmp/akasha-48-sparse-share")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _write(collection, 0, 32, 0)
    collection.upsert_sparse(3, [SparseElement(7, 1.0)])
    _ = collection.snapshot()
    collection.upsert_document(3, _vector(3, 4), _fields(3, 4))
    var dense = collection.snapshot()
    ref stats = collection._read_generations[].stats
    var copies = stats.descriptor_copies
    var freezes = stats.head_freezes
    collection.upsert_sparse(3, [SparseElement(7, 2.0)])
    var sparse = collection.snapshot()
    assert_false(dense._slot[].root.value() is sparse._slot[].root.value())
    # A sparse-only update refreezes only the head; older runs are shared.
    var layers = dense._slot[].root.value()[].layer_count()
    assert_equal(layers, sparse._slot[].root.value()[].layer_count())
    for layer in range(layers - 1):
        assert_true(
            dense._slot[].root.value()[].layers[layer].run
            is sparse._slot[].root.value()[].layers[layer].run
        )
    # One descriptor recorded into the head, then the head's copy at freeze.
    var head = collection._read_generations[].head_count()
    assert_equal(stats.descriptor_copies - copies, 1 + head)
    assert_equal(stats.head_freezes, freezes + 1)
    ref before = dense._slot[].root.value()[].run(layers - 1).memtable
    ref after = sparse._slot[].root.value()[].run(layers - 1).memtable
    ref old_entry = before.entry_ref_at(before.ordinal_for(3))
    ref new_entry = after.entry_ref_at(after.ordinal_for(3))
    assert_equal(old_entry.dense_address(), new_entry.dense_address())
    assert_equal(old_entry.payload_address(), new_entry.payload_address())
    assert_true(old_entry.sparse_address() != new_entry.sparse_address())
    assert_equal(_copied_dense_bytes(sparse, collection), 0)
    assert_equal(
        dense.search_sparse_dot([SparseElement(7, 1.0)], 1)[0].score,
        Float32(1.0),
    )
    assert_equal(
        sparse.search_sparse_dot([SparseElement(7, 1.0)], 1)[0].score,
        Float32(2.0),
    )

    var owned = sparse.get(3)
    owned.value().vector[0] = 999.0
    owned.value().fields[0].name = "changed"
    assert_equal(sparse.get(3).value().vector[0], _vector(3, 4)[0])
    assert_equal(dense.get(3).value().vector[0], _vector(3, 4)[0])
    assert_equal(sparse.get(3).value().fields[0].name, "group")
    assert_equal(collection.get(3).value().vector[0], _vector(3, 4)[0])
    dense.close()
    sparse.close()
    collection.close()


def test_atomic_batch_spanning_rollover_is_all_or_nothing() raises:
    var path = String("/tmp/akasha-48-atomic-batch")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _write(collection, 0, 10, 0)
    var before = collection.snapshot()
    var mutations = List[BatchMutation]()
    for id in range(100, 1600):
        mutations.append(BatchMutation.upsert(id, _vector(id, 1)))
    mutations.append(BatchMutation.delete(5))
    var result = collection.apply_batch(mutations)
    assert_true(collection._read_generations[].stats.rollovers >= 1)
    var after = collection.snapshot()
    assert_equal(after.last_sequence(), result.last_sequence)
    assert_equal(len(before.documents()), 10)
    assert_true(Bool(before.get(5)))
    assert_false(Bool(before.get(100)))
    assert_equal(len(after.documents()), 10 - 1 + 1500)
    assert_false(Bool(after.get(5)))
    assert_true(Bool(after.get(1599)))
    assert_true(Bool(after.get(100)))
    _assert_equivalent(after, _flat(after, collection))
    before.close()
    after.close()
    collection.close()


def test_failure_before_publication_keeps_old_root() raises:
    var path = String("/tmp/akasha-48-publish-failure")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _write(collection, 0, 8, 0)
    var snapshot = collection.snapshot()
    var revision = collection._read_generations[].revision
    var copies = collection._read_generations[].stats.descriptor_copies
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.upsert(50, _vector(50, 0)))
    mutations.append(BatchMutation.upsert(51, [1.0]))
    with assert_raises():
        _ = collection.apply_batch(mutations)
    with assert_raises():
        collection.upsert(60, [1.0])
    var after = collection.snapshot()
    assert_true(after._slot[].root.value() is snapshot._slot[].root.value())
    assert_equal(collection._read_generations[].revision, revision)
    assert_equal(collection._read_generations[].stats.descriptor_copies, copies)
    assert_false(Bool(after.get(50)))
    snapshot.close()
    after.close()
    collection.close()

    # A post-commit publisher fault cannot reject the write; it drops derived
    # state and the next capture rebuilds from the writer table.
    var table = MemTable(4)
    var pins = ArcPointer(GenerationPinRegistry())
    var config = CollectionConfig.defaults(4)
    var cache = ReadGenerationCache()
    table.apply_upsert(1, 1, _vector(1, 0))
    var old = cache.acquire(config, 0, 1, table, pins)
    table.apply_upsert(2, 2, _vector(2, 0))
    cache.record(table, [999], 2)
    assert_false(Bool(cache.root))
    assert_equal(cache.sealed_count(), 0)
    var rebuilt = cache.acquire(config, 0, 2, table, pins)
    assert_equal(cache.stats.base_builds, 2)
    assert_equal(rebuilt[].visible_count, 2)
    assert_equal(old[].visible_count, 1)
    # A publisher that silently missed a write refuses to publish stale data.
    table.apply_upsert(3, 3, _vector(3, 0))
    with assert_raises():
        _ = cache.acquire(config, 0, 3, table, pins)


def _scoped_capture(mut collection: PersistentCollection) raises:
    var scoped = collection.snapshot()
    assert_equal(scoped._slot[].root.value()[].layer_count(), 3)


def test_close_and_raii_release_layered_pins() raises:
    var path = String("/tmp/akasha-48-close-raii")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _write(collection, 0, 16, 0)
    _ = collection.snapshot()
    _write(collection, 100, HEAD_MAX_POINTS, 1)
    collection.upsert(3, _vector(3, 5))
    var layered = collection.snapshot()
    var sibling = collection.snapshot()
    assert_equal(layered._slot[].root.value()[].layer_count(), 3)
    _scoped_capture(collection)
    sibling.close()
    assert_equal(layered.get(3).value().vector[0], _vector(3, 5)[0])
    assert_equal(collection._pins[].active_count(), 1)
    collection.close()
    assert_false(Bool(collection._read_generations[].root))
    assert_equal(collection._read_generations[].sealed_count(), 0)
    assert_equal(len(layered.documents()), 16 + HEAD_MAX_POINTS)
    assert_equal(collection._pins[].active_count(), 1)
    layered.close()
    assert_equal(collection._pins[].active_count(), 0)


def test_shadowing_precedes_filters_topk_and_device_layout() raises:
    var path = String("/tmp/akasha-48-shadowing")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    _write(collection, 0, 200, 0)
    collection.upsert_document(8, [100.0, 100.0, 100.0, 100.0], _fields(8, 0))
    var base = collection.snapshot()
    var query: List[Float32] = [1.0, 1.0, 1.0, 1.0]
    assert_equal(base.search_dot(query, 1)[0].id, 8)
    assert_equal(base.search_dot_where(query, 1, _even())[0].id, 8)
    collection.upsert_document(
        8, [-100.0, -100.0, -100.0, -100.0], _fields(9, 0)
    )
    collection.delete(10)
    var shadowed = collection.snapshot()
    assert_equal(shadowed._slot[].root.value()[].layer_count(), 2)
    var top = shadowed.search_dot(query, 3)
    for result in top:
        assert_true(result.id != 8)
    for result in shadowed.search_dot_where(query, 200, _even()):
        assert_true(result.id != 8 and result.id != 10)
    _assert_equivalent(shadowed, _flat(shadowed, collection))

    # Device tables belong to one root's layout; roots never share them.
    var queries = List[List[Float32]]()
    queries.append(query.copy())
    var options = GpuExecutionOptions(enabled=True, min_work_items=1)
    var old_device = base.search_device_dot_batch[use_accelerator=False](
        queries, 1, options
    )
    var new_device = shadowed.search_device_dot_batch[use_accelerator=False](
        queries, 1, options
    )
    assert_equal(old_device.results[0][0].id, 8)
    assert_true(new_device.results[0][0].id != 8)
    ref base_root = base._slot[].root.value()[]
    ref shadowed_root = shadowed._slot[].root.value()[]
    assert_true(base_root.device[].table.value() is base_root.layers[0].run)
    assert_false(
        shadowed_root.device[].table.value() is base_root.device[].table.value()
    )
    assert_equal(
        shadowed_root.device[].table.value()[].memtable.live_count(),
        shadowed_root.visible_count,
    )
    shadowed.close()
    assert_false(Bool(shadowed._slot[].root))
    assert_true(Bool(base._slot[].root.value()[].device[].table))

    _write(collection, 1000, HEAD_MAX_POINTS + 3, 2)
    collection.upsert_document(1001, [50.0, 50.0, 50.0, 50.0], _fields(1001, 0))
    var chained = collection.snapshot()
    assert_equal(chained._slot[].root.value()[].layer_count(), 3)
    assert_equal(chained.search_dot(query, 1)[0].id, 1001)
    _assert_equivalent(chained, _flat(chained, collection))
    base.close()
    chained.close()
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
