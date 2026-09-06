from akasha import (
    BatchMutation,
    Bitmap,
    CollectionConfig,
    DocumentField,
    FilterCondition,
    FilterExpression,
    MetricKind,
    PayloadValue,
    PersistentCollection,
)
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite


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
    for sequence in range(512):
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


def test_upsert_updates_graph_before_any_query() raises:
    var path = String("/tmp/akasha-task18-immediate-graph")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(80):
        collection.upsert(id, [Float32(id)])

    assert_equal(collection._hnsw.point_count(), 80)
    assert_equal(collection._hnsw.build_slot_count(), 80)


def test_document_upsert_graph_update_borrows_by_ordinal_without_record_clone() raises:
    var path = String("/tmp/akasha-task18-upsert-borrowed-vector")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    for id in range(80):
        collection.upsert(id, [Float32(id), Float32(80 - id)])
    var fields = List[DocumentField]()
    for index in range(128):
        fields.append(
            DocumentField(
                "payload_" + String(index),
                PayloadValue.integer(Int64(index)),
            )
        )

    collection.upsert_document(999, [999.0, -999.0], fields^)

    assert_equal(collection.last_hnsw_upsert_ordinal_lookups(), 1)
    assert_equal(collection.last_hnsw_upsert_memtable_id_scans(), 0)
    assert_equal(collection.last_hnsw_upsert_record_clones(), 0)
    assert_equal(collection.hnsw_available(), True)
    assert_equal(collection._hnsw.point_count(), 81)


def test_replace_and_delete_update_graph_without_query_rebuild() raises:
    var path = String("/tmp/akasha-task18-mutation-graph")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(80):
        collection.upsert(id, [Float32(id)])

    collection.upsert(79, [-1.0])
    collection.delete(78)
    assert_equal(collection._hnsw.point_count(), 81)
    assert_equal(collection._hnsw.inactive_count(), 2)
    var build_distances = collection._hnsw.build_distance_evaluations()

    var results = collection.search_l2_approx([79.0], 2, 80)
    assert_equal(results[0].id, 77)
    assert_equal(results[1].id, 76)
    assert_equal(
        collection._hnsw.build_distance_evaluations(), build_distances
    )
    assert_equal(collection.last_dense_plan_reason(), "ann")


def test_query_observes_rebuild_need_without_performing_maintenance() raises:
    var path = String("/tmp/akasha-task19-query-observes-rebuild")
    _reset(path)
    var config = CollectionConfig.defaults(1)
    config.rebuild_inactive_percent = 1
    var collection = PersistentCollection.open_with_config(path, config)
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    collection.upsert(79, [-1.0])
    assert_true(collection._hnsw.needs_rebuild())
    var slots_before = collection.hnsw_slot_count()
    var inactive_before = collection.hnsw_inactive_count()
    var build_before = collection.hnsw_build_distance_evaluations()

    _ = collection.search_l2_approx([79.0], 3, 64)

    assert_true(collection._hnsw.needs_rebuild())
    assert_equal(collection.hnsw_slot_count(), slots_before)
    assert_equal(collection.hnsw_inactive_count(), inactive_before)
    assert_equal(collection.hnsw_build_distance_evaluations(), build_before)


def test_metric_mismatch_returns_exact_equivalent_results() raises:
    var path = String("/tmp/akasha-task18-metric-mismatch")
    _reset(path)
    var config = CollectionConfig.defaults(2)
    config.ann_metric = MetricKind.dot()
    var collection = PersistentCollection.open_with_config(path, config)
    for id in range(80):
        collection.upsert(id, [Float32(id), Float32(79 - id)])

    var query: List[Float32] = [70.0, 9.0]
    var exact = collection.search_l2(query, 5)
    var approximate = collection.search_l2_approx(query, 5, 32)
    assert_equal(len(approximate), len(exact))
    for index in range(len(exact)):
        assert_equal(approximate[index].id, exact[index].id)
    assert_equal(collection.last_dense_plan_reason(), "metric_mismatch")


def test_small_and_recovered_graph_plans_are_correct() raises:
    var small_path = String("/tmp/akasha-task18-small-plan")
    _reset(small_path)
    var small = PersistentCollection.open(small_path, 1)
    for id in range(10):
        small.upsert(id, [Float32(id)])
    var small_exact = small.search_l2([9.0], 3)
    var small_approx = small.search_l2_approx([9.0], 3, 16)
    for index in range(len(small_exact)):
        assert_equal(small_approx[index].id, small_exact[index].id)
    assert_equal(small.last_dense_plan_reason(), "small_collection")

    var recovery_path = String("/tmp/akasha-task18-unready-plan")
    _reset(recovery_path)
    var original = PersistentCollection.open(recovery_path, 1)
    for id in range(80):
        original.upsert(id, [Float32(id)])
    original.close()
    var recovered = PersistentCollection.open(recovery_path, 1)
    # Task 22 rebuilds when no committed sidecar exists.
    assert_equal(recovered.hnsw_available(), True)
    var recovered_exact = recovered.search_l2([79.0], 3)
    var recovered_approx = recovered.search_l2_approx([79.0], 3, 32)
    for index in range(len(recovered_exact)):
        assert_equal(recovered_approx[index].id, recovered_exact[index].id)
    assert_equal(recovered.last_dense_plan_reason(), "ann")


def test_graph_mutation_failure_keeps_authoritative_exact_search() raises:
    var path = String("/tmp/akasha-task18-mutation-failure")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    var sequence_before = collection.last_sequence()

    collection._hnsw._delta.config.dimension = 2
    collection.upsert(999, [999.0])

    assert_equal(collection.last_sequence(), sequence_before + 1)
    assert_true(Bool(collection.get(999)))
    assert_equal(collection.hnsw_available(), False)
    assert_equal(collection.hnsw_unavailable_reason(), "mutation_failed")
    var result = collection.search_l2_approx([999.0], 1, 32)
    assert_equal(result[0].id, 999)
    assert_equal(collection.last_dense_plan_reason(), "graph_unavailable")


def test_filtered_ann_uses_bitmap_admission_and_authoritative_rerank() raises:
    var path = String("/tmp/akasha-task18-filtered-ann")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    for id in range(96):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField(
                "keep", PayloadValue.boolean(id % 3 != 0)
            )
        )
        collection.upsert_document(
            id, [Float32(id), Float32(95 - id)], fields^
        )
    var expression = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    var query: List[Float32] = [70.0, 25.0]
    var exact = collection.search_l2_where(query, 5, expression)
    var approximate = collection.search_l2_approx_where(
        query, 5, 8, expression
    )
    assert_equal(collection.last_dense_plan_reason(), "ann")
    assert_true(
        collection._hnsw.last_search_stats().filtered_rejections > 0
    )
    # The final result remains Top-5, but authoritative rerank receives the
    # complete max(k, ef) candidate pool from the active source.
    assert_equal(collection.last_hnsw_rerank_candidate_count(), 8)
    assert_equal(collection.last_hnsw_rerank_ordinal_lookups(), 8)
    assert_equal(collection.last_hnsw_rerank_linear_id_scans(), 0)
    assert_equal(collection.last_hnsw_rerank_payload_clones(), 0)
    assert_equal(len(approximate), len(exact))
    for index in range(len(exact)):
        assert_equal(approximate[index].id, exact[index].id)


def test_batch_updates_each_final_id_once_after_authoritative_commit() raises:
    var path = String("/tmp/akasha-task18-batch-graph")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.upsert(1, [101.0]))
    mutations.append(BatchMutation.upsert(1, [201.0]))
    mutations.append(BatchMutation.upsert(1, [301.0]))
    _ = collection.apply_batch(mutations)

    assert_equal(collection.hnsw_slot_count(), 81)
    assert_equal(collection.hnsw_inactive_count(), 1)
    var result = collection.search_l2_approx([301.0], 1, 32)
    assert_equal(result[0].id, 1)


def test_known_live_delete_missing_from_graph_quarantines_after_commit() raises:
    var path = String("/tmp/akasha-task18-delete-divergence")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    assert_true(collection._hnsw.delete(10))

    collection.delete(10)

    assert_equal(Bool(collection.get(10)), False)
    assert_equal(collection.hnsw_available(), False)
    assert_equal(collection.hnsw_unavailable_reason(), "mutation_failed")


def test_unknown_delete_miss_is_safe_but_batch_known_live_miss_is_not() raises:
    var unknown_path = String("/tmp/akasha-task18-unknown-delete")
    _reset(unknown_path)
    var unknown = PersistentCollection.open(unknown_path, 1)
    unknown.delete(999)
    assert_true(unknown.hnsw_available())

    var batch_path = String("/tmp/akasha-task18-batch-delete-divergence")
    _reset(batch_path)
    var batch = PersistentCollection.open(batch_path, 1)
    for id in range(80):
        batch.upsert(id, [Float32(id)])
    assert_true(batch._hnsw.delete(20))
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.delete(20))
    _ = batch.apply_batch(mutations)
    assert_equal(Bool(batch.get(20)), False)
    assert_equal(batch.hnsw_available(), False)
    assert_equal(batch.hnsw_unavailable_reason(), "mutation_failed")


def test_corrupt_candidate_shortfall_quarantines_and_exact_falls_back() raises:
    var path = String("/tmp/akasha-task18-candidate-shortfall")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    for slot in range(collection._hnsw._delta.graph.slot_count()):
        collection._hnsw._delta.graph.current_flags[slot] = False

    var result = collection.search_l2_approx([79.0], 3, 32)

    assert_equal(len(result), 3)
    assert_equal(result[0].id, 79)
    assert_equal(result[1].id, 78)
    assert_equal(result[2].id, 77)
    assert_equal(collection.hnsw_available(), False)
    assert_equal(collection.hnsw_unavailable_reason(), "search_failed")
    assert_equal(collection.last_dense_plan_reason(), "graph_unavailable")


def test_unfiltered_and_filtered_queries_share_one_lazy_id_lookup() raises:
    var path = String("/tmp/akasha-task18-lazy-id-lookup")
    _reset(path)
    var original = PersistentCollection.open(path, 1)
    for id in range(80):
        original.upsert(id, [Float32(id)])
    original.close()

    var reopened = PersistentCollection.open(path, 1)
    # With no committed checkpoint sidecar, reopen rebuilds authoritative data.
    assert_equal(reopened.hnsw_cache_hit(), False)
    assert_equal(reopened.hnsw_id_lookup_build_count(), 0)
    _ = reopened.search_l2_approx([79.0], 3, 32)
    assert_equal(reopened.hnsw_id_lookup_build_count(), 1)
    _ = reopened.search_l2_approx([78.0], 3, 32)
    assert_equal(reopened.hnsw_id_lookup_build_count(), 1)

    var filtered_path = String("/tmp/akasha-task18-lazy-filter-lookup")
    _reset(filtered_path)
    var filtered = PersistentCollection.open(filtered_path, 1)
    for id in range(80):
        var fields = List[DocumentField]()
        fields.append(
            DocumentField("keep", PayloadValue.boolean(id % 2 == 0))
        )
        filtered.upsert_document(id, [Float32(id)], fields^)
    var expression = FilterExpression.condition(
        FilterCondition.equal("keep", PayloadValue.boolean(True))
    )
    assert_equal(filtered.hnsw_id_lookup_build_count(), 0)
    _ = filtered.search_l2_approx_where([79.0], 3, 32, expression)
    assert_equal(filtered.hnsw_id_lookup_build_count(), 1)
    _ = filtered.search_l2_approx_where([78.0], 3, 32, expression)
    assert_equal(filtered.hnsw_id_lookup_build_count(), 1)


def test_built_id_lookup_extends_incrementally_for_all_new_slot_paths() raises:
    var path = String("/tmp/akasha-task25-incremental-id-lookup")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    _ = collection.search_l2_approx([79.0], 3, 32)
    assert_equal(collection.hnsw_id_lookup_build_count(), 1)
    assert_equal(
        collection._hnsw_id_lookup.value().construction_scanned_entries(), 80
    )

    collection.upsert(100, [100.0])
    var fields = List[DocumentField]()
    fields.append(DocumentField("kind", PayloadValue.string("new")))
    collection.upsert_document(101, [101.0], fields^)
    collection.delete(102)
    var mutations = List[BatchMutation]()
    mutations.append(BatchMutation.upsert(103, [103.0]))
    mutations.append(BatchMutation.upsert(104, [104.0]))
    _ = collection.apply_batch(mutations)

    _ = collection.search_l2_approx([104.0], 3, 32)
    assert_equal(collection.hnsw_id_lookup_build_count(), 1)
    assert_equal(collection._hnsw_id_lookup.value().entry_count(), 85)
    assert_equal(collection.hnsw_id_lookup_incremental_append_count(), 5)
    assert_equal(
        collection._hnsw_id_lookup.value().construction_scanned_entries(), 80
    )
    assert_true(collection.hnsw_available())


def test_exact_and_ann_rerank_share_authoritative_f32_scores() raises:
    var path = String("/tmp/akasha-task25-authoritative-f32-score")
    _reset(path)
    var config = CollectionConfig.defaults(3)
    config.ann_metric = MetricKind.cosine()
    var collection = PersistentCollection.open_with_config(path, config)
    for id in range(80):
        if id == 0:
            collection.upsert(id, [1.0, 0.0, 0.0])
        elif id == 1:
            collection.upsert(id, [-1.0, 0.0, 0.0])
        elif id == 2:
            collection.upsert(id, [1.0, 0.0000001, 0.0])
        else:
            collection.upsert(
                id,
                [
                    10_000_000_000.0 + Float32(id * 1024),
                    10_000_000_000.0 - Float32(id * 512),
                    Float32(id % 7 + 1),
                ],
            )
    var query: List[Float32] = [10_000_000_000.0, 10_000_000_000.0, 3.0]

    var exact = collection.search_cosine(query, 80)
    var approximate = collection.search_cosine_approx(query, 80, 80)

    assert_equal(collection.last_dense_plan_reason(), "ann")
    assert_equal(len(approximate), len(exact))
    for index in range(len(exact)):
        assert_equal(approximate[index].id, exact[index].id)
        assert_equal(approximate[index].score, exact[index].score)
    assert_false(approximate[0].score > 1.0)

    var boundary_query: List[Float32] = [1.0, 0.0, 0.0]
    var boundary_exact = collection.search_cosine(boundary_query, 80)
    var boundary_ann = collection.search_cosine_approx(
        boundary_query, 80, 80
    )
    var saw_positive_boundary = False
    var saw_negative_boundary = False
    for index in range(len(boundary_exact)):
        assert_equal(boundary_ann[index].id, boundary_exact[index].id)
        assert_equal(boundary_ann[index].score, boundary_exact[index].score)
        if boundary_exact[index].id == 0:
            assert_equal(boundary_exact[index].score, Float32(1.0))
            saw_positive_boundary = True
        elif boundary_exact[index].id == 1:
            assert_equal(boundary_exact[index].score, Float32(-1.0))
            saw_negative_boundary = True
    assert_true(saw_positive_boundary)
    assert_true(saw_negative_boundary)

    var dot_path = String("/tmp/akasha-task25-authoritative-f32-dot")
    _reset(dot_path)
    var dot_config = CollectionConfig.defaults(2)
    dot_config.ann_metric = MetricKind.dot()
    var dot = PersistentCollection.open_with_config(dot_path, dot_config)
    for id in range(80):
        dot.upsert(id, [Float32(id - 40), Float32(40 - id)])
    var dot_query: List[Float32] = [3.25, -7.5]
    var dot_exact = dot.search_dot(dot_query, 10)
    var dot_ann = dot.search_dot_approx(dot_query, 10, 80)
    assert_equal(dot.last_dense_plan_reason(), "ann")
    for index in range(len(dot_exact)):
        assert_equal(dot_ann[index].id, dot_exact[index].id)
        assert_equal(dot_ann[index].score, dot_exact[index].score)


def test_owned_overlay_shortfall_is_valid_ann_and_never_quarantines() raises:
    var path = String("/tmp/akasha-task25-owned-overlay-shortfall")
    _reset(path)
    var config = CollectionConfig.defaults(1)
    config.m0 = config.m
    config.delta_max_points = 256
    config.rebuild_inactive_percent = 90
    var collection = PersistentCollection.open_with_config(path, config)
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    for id in range(60):
        collection.upsert(id, [Float32(1_000 + id)])
    for id in range(60, 75):
        collection.delete(id)

    var exact = collection.search_l2([0.0], 5)
    var approximate = collection.search_l2_approx([0.0], 5, 5)

    for index in range(len(exact)):
        assert_equal(approximate[index].id, exact[index].id)
        assert_equal(approximate[index].score, exact[index].score)
    assert_true(collection.hnsw_available())
    assert_equal(collection.hnsw_unavailable_reason(), "")
    assert_equal(collection.last_dense_plan_reason(), "ann")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
