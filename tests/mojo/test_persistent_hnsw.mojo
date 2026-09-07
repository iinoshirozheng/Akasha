from akasha import (
    CollectionConfig,
    DocumentField,
    FilterCondition,
    FilterExpression,
    PayloadValue,
    PersistentCollection,
    MetricKind,
    ScalarKind,
)
from akasha.storage.filesystem import (
    append_file_sync,
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import (
    load_manifest,
    Manifest,
    publish_manifest,
    SegmentDescriptor,
)
from akasha.index.hnsw import HnswIndex
from akasha.storage.checksum import crc32_range
from akasha.storage.hnsw_store import write_hnsw_snapshot
from std.ffi import c_int, external_call
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


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
    for sequence in range(256):
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
        remove_file_if_exists(
            directory + "/hnsw-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/hnsw-" + String(sequence) + ".bin.tmp"
        )


def _dot_config(dimension: Int) -> CollectionConfig:
    var config = CollectionConfig.defaults(dimension)
    config.ann_metric = MetricKind.dot()
    return config^


def _cacheable_l2_config(dimension: Int) -> CollectionConfig:
    var config = CollectionConfig.defaults(dimension)
    config.m0 = config.m
    return config^


def _stored_hnsw_checksum(bytes: List[UInt8]) -> UInt32:
    var offset = len(bytes) - 4
    return (
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << UInt32(8))
        | (UInt32(bytes[offset + 2]) << UInt32(16))
        | (UInt32(bytes[offset + 3]) << UInt32(24))
    )


def _fcntl_getfd(descriptor: Int32) -> Int32:
    return Int32(
        external_call["fcntl", c_int, num_fixed_args=2](
            c_int(descriptor), c_int(1)
        )
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
    assert_equal(
        collection.last_dense_plan_reason(), "filtered_ann_exhausted"
    )
    assert_equal(collection.hnsw_available(), True)


def _clone_descriptors(manifest: Manifest) raises -> List[SegmentDescriptor]:
    var descriptors = List[SegmentDescriptor]()
    for index in range(len(manifest.segments)):
        descriptors.append(manifest.segments[index].clone())
    return descriptors^


def _build_checkpoint(path: String) raises -> CollectionConfig:
    _reset(path)
    var config = _cacheable_l2_config(1)
    var collection = PersistentCollection.open_with_config(path, config.copy())
    for id in range(1, 81):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    collection.close()
    return config^


def test_flush_commits_v3_hnsw_and_reopen_uses_mapped_sidecar() raises:
    var path = String("/tmp/akasha-task22-owned-sidecar")
    var config = _build_checkpoint(path)
    var manifest = load_manifest(path, 1)
    assert_equal(manifest.format_version, 3)
    assert_true(Bool(manifest.hnsw_name))
    assert_equal(manifest.hnsw_name.value(), "hnsw-80.bin")
    assert_true(path_exists(path + "/" + manifest.hnsw_name.value()))
    assert_equal(
        manifest.hnsw_config_fingerprint.value(), config.fingerprint()
    )
    assert_equal(manifest.hnsw_point_count.value(), UInt64(80))

    var reopened = PersistentCollection.open_with_config(path, config.copy())
    assert_true(reopened.hnsw_available())
    assert_false(reopened.hnsw_cache_hit())
    assert_true(reopened._hnsw.base_is_mapped())
    assert_equal(reopened._hnsw.delta_slot_count(), 0)
    # Successful mapping performs neither owned decode nor graph construction.
    assert_equal(reopened.hnsw_build_distance_evaluations(), 0)
    var result = reopened.search_l2_approx([80.0], 3, 80)
    assert_equal(result[0].id, 80)
    assert_equal(result[1].id, 79)
    assert_equal(result[2].id, 78)
    reopened.close()


def test_repeated_collection_close_releases_retained_mapped_base_once() raises:
    var path = String("/tmp/akasha-task25-mapped-close")
    var config = _build_checkpoint(path)
    var first = PersistentCollection.open_with_config(path, config.copy())
    var first_descriptor = (
        first._hnsw._mapped_base._mapping._descriptor_for_testing()
    )
    assert_true(_fcntl_getfd(first_descriptor) >= 0)

    first.close()
    assert_equal(_fcntl_getfd(first_descriptor), Int32(-1))
    with assert_raises():
        first._hnsw._mapped_base.validate_search_ready()

    # Keep `first` alive while the OS may reuse its descriptor for `second`.
    # A repeated close on the retained object must not close the new owner.
    var second = PersistentCollection.open_with_config(path, config.copy())
    var second_descriptor = (
        second._hnsw._mapped_base._mapping._descriptor_for_testing()
    )
    assert_true(_fcntl_getfd(second_descriptor) >= 0)
    first.close()
    assert_true(_fcntl_getfd(second_descriptor) >= 0)
    second.close()
    assert_equal(_fcntl_getfd(second_descriptor), Int32(-1))


def test_queries_match_ids_and_scores_before_and_after_sidecar_reopen() raises:
    var path = String("/tmp/akasha-task22-query-equivalence")
    _reset(path)
    var config = _cacheable_l2_config(2)
    var collection = PersistentCollection.open_with_config(path, config.copy())
    for id in range(1, 81):
        collection.upsert(id, [Float32(id), Float32(id % 9)])
    var before_a = collection.search_l2_approx([80.0, 8.0], 5, 80)
    var before_b = collection.search_l2_approx([37.0, 1.0], 5, 80)
    var before_c = collection.search_l2_approx([1.0, 1.0], 5, 80)
    collection.flush()
    collection.close()

    var reopened = PersistentCollection.open_with_config(path, config.copy())
    var after_a = reopened.search_l2_approx([80.0, 8.0], 5, 80)
    var after_b = reopened.search_l2_approx([37.0, 1.0], 5, 80)
    var after_c = reopened.search_l2_approx([1.0, 1.0], 5, 80)
    for index in range(5):
        assert_equal(after_a[index].id, before_a[index].id)
        assert_equal(after_a[index].score, before_a[index].score)
        assert_equal(after_b[index].id, before_b[index].id)
        assert_equal(after_b[index].score, before_b[index].score)
        assert_equal(after_c[index].id, before_c[index].id)
        assert_equal(after_c[index].score, before_c[index].score)
    reopened.close()


def test_reopen_replays_newer_wal_mutations_into_mapped_base_delta() raises:
    var path = String("/tmp/akasha-task22-sidecar-wal-replay")
    var config = _build_checkpoint(path)
    var collection = PersistentCollection.open_with_config(path, config.copy())
    collection.upsert(80, [1.0])
    collection.delete(79)
    collection.close()

    var reopened = PersistentCollection.open_with_config(path, config.copy())
    # The immutable mapped checkpoint stays at 80 slots. Replacement replay
    # creates one delta slot, while a base deletion is represented solely by
    # the current-source map and never mutates the base.
    assert_true(reopened._hnsw.base_is_mapped())
    assert_equal(reopened._hnsw.base_slot_count(), 80)
    assert_equal(reopened._hnsw.delta_slot_count(), 1)
    assert_equal(reopened._hnsw._mapped_base.id_at(UInt32(79)), 80)
    assert_equal(
        reopened._hnsw._mapped_base.vector_value(UInt32(79), 0),
        Float32(80.0),
    )
    assert_true(reopened._hnsw._mapped_base.is_current(UInt32(78)))
    assert_equal(reopened.hnsw_slot_count(), 81)
    assert_equal(reopened.hnsw_inactive_count(), 2)
    assert_equal(reopened.search_l2_approx([80.0], 1, 80)[0].id, 78)
    reopened.flush()
    # Below the delta threshold, the authoritative segment commits as v2 and
    # the in-memory mapped-base overlay remains intact without rebuilding.
    assert_false(reopened._hnsw.checkpoint_ready())
    assert_true(reopened._hnsw.base_is_mapped())
    assert_equal(reopened._hnsw.base_slot_count(), 80)
    assert_equal(reopened._hnsw.delta_slot_count(), 1)
    var below_threshold = load_manifest(path, 1)
    assert_equal(below_threshold.format_version, 2)
    assert_false(Bool(below_threshold.hnsw_name))
    assert_false(path_exists(path + "/hnsw-80.bin"))
    var mutation_count = reopened._hnsw_mutations_since_rebuild
    reopened.flush()
    assert_equal(reopened._hnsw_mutations_since_rebuild, mutation_count)
    assert_false(reopened._hnsw.checkpoint_ready())

    # Explicit maintenance materializes a complete replacement sidecar even
    # though the threshold has not fired.
    reopened.rebuild_hnsw()
    reopened.flush()
    assert_true(reopened._hnsw.checkpoint_ready())
    assert_true(Bool(load_manifest(path, 1).hnsw_name))
    reopened.close()

    var committed = PersistentCollection.open_with_config(path, config.copy())
    assert_true(committed._hnsw.base_is_mapped())
    assert_equal(committed._hnsw.base_slot_count(), 79)
    assert_equal(committed._hnsw.delta_slot_count(), 0)
    assert_equal(committed.search_l2_approx([80.0], 1, 80)[0].id, 78)
    committed.close()


def test_manifest_without_sidecar_rebuilds_from_authoritative_records() raises:
    var path = String("/tmp/akasha-task22-v2-rebuild")
    var config = _build_checkpoint(path)
    var current = load_manifest(path, 1)
    var legacy = Manifest.with_segments(
        1,
        current.generation,
        current.last_sequence,
        _clone_descriptors(current),
    )
    publish_manifest(path, legacy)
    remove_file_if_exists(path + "/hnsw.cache")

    var reopened = PersistentCollection.open_with_config(path, config.copy())
    assert_true(reopened.hnsw_available())
    assert_true(reopened.hnsw_build_distance_evaluations() > 0)
    assert_equal(reopened.search_l2_approx([80.0], 1, 80)[0].id, 80)
    reopened.close()


def test_true_v1_manifest_rebuilds_from_authoritative_segment() raises:
    var path = String("/tmp/akasha-task22-v1-rebuild")
    var config = _build_checkpoint(path)
    var current = load_manifest(path, 1)
    var descriptor = current.segments[0].clone()
    var legacy = Manifest(
        1,
        current.last_sequence,
        descriptor.checksum,
        descriptor.name,
    )
    publish_manifest(path, legacy)
    remove_file_if_exists(path + "/hnsw.cache")
    var reopened = PersistentCollection.open_with_config(path, config.copy())
    assert_true(reopened.hnsw_available())
    assert_true(reopened.hnsw_build_distance_evaluations() > 0)
    assert_equal(reopened.search_l2_approx([80.0], 1, 80)[0].id, 80)
    reopened.close()


def test_compact_checkpoint_publishes_v2_sidecar_through_manifest_v3() raises:
    var path = String("/tmp/akasha-task22-non-f32-checkpoint")
    _reset(path)
    var config = CollectionConfig.defaults(1)
    config.scalar_kind = ScalarKind.bf16()
    var collection = PersistentCollection.open_with_config(path, config.copy())
    collection.flush()
    collection.close()
    var manifest = load_manifest(path, 1)
    assert_true(Bool(manifest.hnsw_name))
    assert_equal(manifest.format_version, 3)
    var sidecar = read_file_bytes(path + "/" + manifest.hnsw_name.value())
    assert_equal(sidecar[4], UInt8(2))
    assert_equal(sidecar[5], UInt8(0))


def test_nonempty_bf16_flush_reopen_keeps_exact_data_and_mapped_ann() raises:
    var path = String("/tmp/akasha-task22-bf16-reopen")
    _reset(path)
    var config = CollectionConfig.defaults(1)
    config.scalar_kind = ScalarKind.bf16()
    var collection = PersistentCollection.open_with_config(path, config.copy())
    for id in range(1, 6):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    collection.close()

    var reopened = PersistentCollection.open_with_config(path, config.copy())
    assert_true(reopened.hnsw_available())
    assert_true(reopened._hnsw.base_is_mapped())
    assert_equal(reopened.hnsw_build_distance_evaluations(), 0)
    assert_equal(reopened.search_dot([1.0], 5)[0].id, 5)
    for id in range(1, 6):
        var record = reopened.get(id)
        assert_true(Bool(record))
        assert_equal(record.value().vector[0], Float32(id))
    reopened.close()


def test_sidecar_size_preflight_falls_back_to_v2_and_rotates_wal() raises:
    var path = String("/tmp/akasha-task22-sidecar-limit")
    _reset(path)
    var config = CollectionConfig.defaults(1)
    var collection = PersistentCollection.open_with_config(path, config.copy())
    collection.upsert(1, [1.0])
    collection._hnsw_sidecar_max_bytes_for_test = UInt64(160)
    collection.flush()
    var manifest = load_manifest(path, 1)
    assert_equal(manifest.format_version, 2)
    assert_false(Bool(manifest.hnsw_name))
    assert_equal(len(read_file_bytes(path + "/wal.bin")), 0)
    collection.close()
    var reopened = PersistentCollection.open(path, 1)
    assert_equal(reopened.get(1).value().vector[0], 1.0)
    reopened.close()


def test_invalid_prepared_graph_quarantines_ann_and_flushes_v2() raises:
    var path = String("/tmp/akasha-task22-invalid-prepared-flush")
    _reset(path)
    var config = CollectionConfig.defaults(2)
    config.ann_metric = MetricKind.cosine()
    var collection = PersistentCollection.open_with_config(path, config.copy())
    for id in range(1, 81):
        collection.upsert(id, [Float32(id), 1.0])
    collection.rebuild_hnsw()
    collection._hnsw._owned_base.graph.vector_scalars[0] = 0.0
    collection._hnsw._owned_base.graph.vector_scalars[1] = 0.0

    collection.flush()

    var manifest = load_manifest(path, 2)
    assert_equal(manifest.format_version, 2)
    assert_false(Bool(manifest.hnsw_name))
    assert_equal(len(read_file_bytes(path + "/wal.bin")), 0)
    assert_false(collection.hnsw_available())
    assert_equal(collection.hnsw_unavailable_reason(), "eligibility_failed")
    assert_equal(collection.get(1).value().vector[0], 1.0)
    assert_equal(collection.get(1).value().vector[1], 1.0)
    collection.close()

    var reopened = PersistentCollection.open_with_config(path, config.copy())
    assert_equal(reopened.get(1).value().vector[0], 1.0)
    assert_equal(reopened.get(1).value().vector[1], 1.0)
    reopened.close()


def test_missing_sidecar_rebuilds_safely() raises:
    var missing_path = String("/tmp/akasha-task22-missing-sidecar")
    var config = _build_checkpoint(missing_path)
    var missing_manifest = load_manifest(missing_path, 1)
    remove_file_if_exists(
        missing_path + "/" + missing_manifest.hnsw_name.value()
    )
    var missing = PersistentCollection.open_with_config(
        missing_path, config.copy()
    )
    assert_true(missing.hnsw_available())
    assert_true(missing.hnsw_build_distance_evaluations() > 0)
    missing.close()


def test_stale_manifest_config_fingerprint_rebuilds_safely() raises:
    var stale_path = String("/tmp/akasha-task22-stale-sidecar")
    var stale_config = _build_checkpoint(stale_path)
    var current = load_manifest(stale_path, 1)
    var stale = Manifest.with_hnsw(
        1,
        current.generation,
        current.last_sequence,
        _clone_descriptors(current),
        current.hnsw_name.value(),
        current.hnsw_checksum.value(),
        current.hnsw_config_fingerprint.value() + UInt64(1),
        current.hnsw_point_count.value(),
    )
    publish_manifest(stale_path, stale)
    var rebuilt = PersistentCollection.open_with_config(
        stale_path, stale_config.copy()
    )
    assert_true(rebuilt.hnsw_available())
    assert_true(rebuilt.hnsw_build_distance_evaluations() > 0)
    rebuilt.close()


def test_stale_manifest_point_count_rebuilds_safely() raises:
    var path = String("/tmp/akasha-task22-stale-point-count")
    var config = _build_checkpoint(path)
    var current = load_manifest(path, 1)
    var stale = Manifest.with_hnsw(
        1,
        current.generation,
        current.last_sequence,
        _clone_descriptors(current),
        current.hnsw_name.value(),
        current.hnsw_checksum.value(),
        current.hnsw_config_fingerprint.value(),
        current.hnsw_point_count.value() + UInt64(1),
    )
    publish_manifest(path, stale)
    var rebuilt = PersistentCollection.open_with_config(path, config.copy())
    assert_true(rebuilt.hnsw_build_distance_evaluations() > 0)
    rebuilt.flush()
    rebuilt.close()
    var repaired = PersistentCollection.open_with_config(path, config.copy())
    assert_equal(repaired.hnsw_build_distance_evaluations(), 0)
    repaired.close()


def test_stale_manifest_checksum_rebuilds_valid_sidecar() raises:
    var path = String("/tmp/akasha-task22-stale-manifest-checksum")
    var config = _build_checkpoint(path)
    var current = load_manifest(path, 1)
    var stale = Manifest.with_hnsw(
        1,
        current.generation,
        current.last_sequence,
        _clone_descriptors(current),
        current.hnsw_name.value(),
        current.hnsw_checksum.value() + UInt32(1),
        current.hnsw_config_fingerprint.value(),
        current.hnsw_point_count.value(),
    )
    publish_manifest(path, stale)
    var rebuilt = PersistentCollection.open_with_config(path, config.copy())
    assert_true(rebuilt.hnsw_build_distance_evaluations() > 0)
    rebuilt.close()


def test_stale_sidecar_header_sequence_and_config_rebuild_safely() raises:
    var sequence_path = String("/tmp/akasha-task22-stale-header-sequence")
    var config = _build_checkpoint(sequence_path)
    var old_bytes = read_file_bytes(sequence_path + "/hnsw-80.bin")
    var collection = PersistentCollection.open_with_config(
        sequence_path, config.copy()
    )
    # Replace an existing point so the committed live count remains 80; the
    # stale sidecar can then differ only in its encoded sequence.
    collection.upsert(80, [81.0])
    collection.rebuild_hnsw()
    collection.flush()
    collection.close()
    # The filename and manifest describe sequence 81, but these internally
    # valid bytes describe sequence 80.
    write_file_sync(sequence_path + "/hnsw-81.bin", old_bytes)
    var sequence_manifest = load_manifest(sequence_path, 1)
    var stale_sequence = Manifest.with_hnsw(
        1,
        sequence_manifest.generation,
        sequence_manifest.last_sequence,
        _clone_descriptors(sequence_manifest),
        sequence_manifest.hnsw_name.value(),
        _stored_hnsw_checksum(old_bytes),
        sequence_manifest.hnsw_config_fingerprint.value(),
        sequence_manifest.hnsw_point_count.value(),
    )
    publish_manifest(sequence_path, stale_sequence)
    var rebuilt_sequence = PersistentCollection.open_with_config(
        sequence_path, config.copy()
    )
    assert_true(rebuilt_sequence.hnsw_build_distance_evaluations() > 0)
    rebuilt_sequence.close()

    var config_path = String("/tmp/akasha-task22-stale-header-config")
    var expected = _build_checkpoint(config_path)
    var alternate = expected.copy()
    alternate.level_seed += UInt64(1)
    var wrong = HnswIndex(alternate.copy())
    for id in range(1, 81):
        wrong.add(id, [Float32(id)])
    var wrong_info = write_hnsw_snapshot(
        config_path + "/hnsw-80.bin", wrong, UInt64(80)
    )
    var config_manifest = load_manifest(config_path, 1)
    var stale_config = Manifest.with_hnsw(
        1,
        config_manifest.generation,
        config_manifest.last_sequence,
        _clone_descriptors(config_manifest),
        config_manifest.hnsw_name.value(),
        wrong_info.checksum,
        config_manifest.hnsw_config_fingerprint.value(),
        config_manifest.hnsw_point_count.value(),
    )
    publish_manifest(config_path, stale_config)
    var rebuilt_config = PersistentCollection.open_with_config(
        config_path, expected.copy()
    )
    assert_true(rebuilt_config.hnsw_build_distance_evaluations() > 0)
    rebuilt_config.close()


def test_identity_bit_flip_without_crc_rewrite_is_committed_corruption() raises:
    var path = String("/tmp/akasha-task22-identity-bitflip-crc")
    var config = _build_checkpoint(path)
    var manifest = load_manifest(path, 1)
    var sidecar_path = path + "/" + manifest.hnsw_name.value()
    var bytes = read_file_bytes(sidecar_path)
    bytes[24] ^= UInt8(1)  # Encoded sequence identity byte.
    write_file_sync(sidecar_path, bytes)
    with assert_raises():
        _ = PersistentCollection.open_with_config(path, config.copy())


def test_stale_manifest_checksum_precedes_corrupt_file_validation() raises:
    var path = String("/tmp/akasha-task22-stale-checksum-corrupt-file")
    var config = _build_checkpoint(path)
    var current = load_manifest(path, 1)
    var sidecar_path = path + "/" + current.hnsw_name.value()
    var bytes = read_file_bytes(sidecar_path)
    bytes[160] ^= UInt8(1)
    write_file_sync(sidecar_path, bytes)
    var stale = Manifest.with_hnsw(
        1,
        current.generation,
        current.last_sequence,
        _clone_descriptors(current),
        current.hnsw_name.value(),
        current.hnsw_checksum.value() + UInt32(1),
        current.hnsw_config_fingerprint.value(),
        current.hnsw_point_count.value(),
    )
    publish_manifest(path, stale)
    var rebuilt = PersistentCollection.open_with_config(path, config.copy())
    assert_true(rebuilt.hnsw_available())
    assert_true(rebuilt.hnsw_build_distance_evaluations() > 0)
    assert_equal(rebuilt.search_l2_approx([80.0], 1, 80)[0].id, 80)
    rebuilt.close()


def test_corrupt_committed_matching_sidecar_fails_open() raises:
    var path = String("/tmp/akasha-task22-corrupt-sidecar")
    var config = _build_checkpoint(path)
    var manifest = load_manifest(path, 1)
    var sidecar_path = path + "/" + manifest.hnsw_name.value()
    append_file_sync(path + "/wal.bin", [UInt8(1), UInt8(2), UInt8(3)])
    var wal_before = read_file_bytes(path + "/wal.bin")
    var bytes = read_file_bytes(sidecar_path)
    bytes[160] ^= UInt8(1)
    write_file_sync(sidecar_path, bytes)
    with assert_raises():
        _ = PersistentCollection.open_with_config(path, config.copy())
    assert_equal(read_file_bytes(path + "/wal.bin"), wal_before)


def test_valid_crc_with_unsafe_committed_layout_fails_open() raises:
    var path = String("/tmp/akasha-task22-corrupt-sidecar-layout")
    var config = _build_checkpoint(path)
    var manifest = load_manifest(path, 1)
    var sidecar_path = path + "/" + manifest.hnsw_name.value()
    var bytes = read_file_bytes(sidecar_path)
    bytes[12] = UInt8(1)  # Reserved fixed-header byte.
    var checksum_offset = len(bytes) - 4
    var checksum = crc32_range(bytes, 0, checksum_offset)
    for byte_index in range(4):
        bytes[checksum_offset + byte_index] = UInt8(
            checksum >> UInt32(byte_index * 8)
        )
    write_file_sync(sidecar_path, bytes)
    var matching = Manifest.with_hnsw(
        1,
        manifest.generation,
        manifest.last_sequence,
        _clone_descriptors(manifest),
        manifest.hnsw_name.value(),
        checksum,
        manifest.hnsw_config_fingerprint.value(),
        manifest.hnsw_point_count.value(),
    )
    publish_manifest(path, matching)
    with assert_raises():
        _ = PersistentCollection.open_with_config(path, config.copy())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
