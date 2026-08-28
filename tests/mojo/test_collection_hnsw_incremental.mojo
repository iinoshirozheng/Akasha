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
    SearchResult,
)
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_true, TestSuite


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


def test_small_and_unavailable_graph_plans_are_exact_equivalent() raises:
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
    assert_equal(recovered.hnsw_available(), False)
    var recovered_exact = recovered.search_l2([79.0], 3)
    var recovered_approx = recovered.search_l2_approx([79.0], 3, 32)
    for index in range(len(recovered_exact)):
        assert_equal(recovered_approx[index].id, recovered_exact[index].id)
    assert_equal(recovered.last_dense_plan_reason(), "graph_unavailable")


def test_graph_mutation_failure_keeps_authoritative_exact_search() raises:
    var path = String("/tmp/akasha-task18-mutation-failure")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(80):
        collection.upsert(id, [Float32(id)])
    var sequence_before = collection.last_sequence()

    collection._hnsw.config.dimension = 2
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
    assert_true(collection._hnsw.last_search_stats.filtered_rejections > 0)
    assert_equal(collection.last_hnsw_rerank_candidate_count(), 5)
    assert_equal(collection.last_hnsw_rerank_ordinal_lookups(), 5)
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
    for slot in range(collection._hnsw.graph.slot_count()):
        collection._hnsw.graph.current_flags[slot] = False

    var result = collection.search_l2_approx([79.0], 3, 32)

    assert_equal(len(result), 3)
    assert_equal(result[0].id, 79)
    assert_equal(result[1].id, 78)
    assert_equal(result[2].id, 77)
    assert_equal(collection.hnsw_available(), False)
    assert_equal(collection.hnsw_unavailable_reason(), "candidate_invalid")
    assert_equal(collection.last_dense_plan_reason(), "graph_unavailable")


def test_injected_duplicate_missing_and_ineligible_candidates_fall_back() raises:
    var duplicate_path = String("/tmp/akasha-task18-duplicate-candidate")
    _reset(duplicate_path)
    var duplicate = PersistentCollection.open(duplicate_path, 1)
    duplicate.upsert(1, [1.0])
    duplicate.upsert(2, [2.0])
    var duplicate_candidates = List[SearchResult]()
    duplicate_candidates.append(SearchResult(2, 0.0))
    duplicate_candidates.append(SearchResult(2, 0.0))
    var allow_all = Optional[Bitmap]()
    var duplicate_result = duplicate._finish_hnsw_candidates(
        [2.0], 2, 1, duplicate_candidates, 2, allow_all
    )
    assert_equal(duplicate_result[0].id, 2)
    assert_equal(duplicate_result[1].id, 1)
    assert_equal(duplicate.hnsw_available(), False)

    var missing_path = String("/tmp/akasha-task18-missing-candidate")
    _reset(missing_path)
    var missing = PersistentCollection.open(missing_path, 1)
    missing.upsert(1, [1.0])
    var missing_candidates = List[SearchResult]()
    missing_candidates.append(SearchResult(999, 0.0))
    var missing_allow_all = Optional[Bitmap]()
    var missing_result = missing._finish_hnsw_candidates(
        [1.0], 1, 1, missing_candidates, 1, missing_allow_all
    )
    assert_equal(missing_result[0].id, 1)
    assert_equal(missing.hnsw_available(), False)

    var filtered_path = String("/tmp/akasha-task18-ineligible-candidate")
    _reset(filtered_path)
    var filtered = PersistentCollection.open(filtered_path, 1)
    filtered.upsert(1, [1.0])
    filtered.upsert(2, [2.0])
    var allowed_bitmap = Bitmap(2)
    allowed_bitmap.set(0)
    var allowed = Optional(allowed_bitmap^)
    var ineligible_candidates = List[SearchResult]()
    ineligible_candidates.append(SearchResult(2, 0.0))
    var filtered_result = filtered._finish_hnsw_candidates(
        [2.0], 1, 1, ineligible_candidates, 1, allowed
    )
    assert_equal(filtered_result[0].id, 1)
    assert_equal(filtered.hnsw_available(), False)


def test_open_and_unfiltered_queries_do_not_build_filter_id_lookup() raises:
    var path = String("/tmp/akasha-task18-lazy-id-lookup")
    _reset(path)
    var original = PersistentCollection.open(path, 1)
    for id in range(80):
        original.upsert(id, [Float32(id)])
    original.close()

    var reopened = PersistentCollection.open(path, 1)
    # Incremental history makes this default-config cache non-lossless, so
    # reopen exercises the cache-miss/unavailable path.
    assert_equal(reopened.hnsw_cache_hit(), False)
    assert_equal(reopened.hnsw_id_lookup_build_count(), 0)
    _ = reopened.search_l2_approx([79.0], 3, 32)
    assert_equal(reopened.hnsw_id_lookup_build_count(), 0)

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
