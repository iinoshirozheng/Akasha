from akasha import (
    CollectionConfig,
    MetricKind,
    PersistentCollection,
    ScalarKind,
    SparseElement,
)
from akasha.storage import collection_config_exists, load_collection_config
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.lock import CollectionLock
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def _test_directory(suffix: String) -> String:
    var process_id = external_call["getpid", c_int]()
    return String(
        "/tmp/akasha-collection-migration-",
        Int(process_id),
        "-",
        suffix,
    )


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/collection.bin")
    remove_file_if_exists(directory + "/collection.bin.tmp")
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/sparse.wal")
    remove_file_if_exists(directory + "/sparse.wal.tmp")
    for sequence in range(5):
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-delta-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/sparse-delta-" + String(sequence) + ".bin"
        )


def _assert_bytes_equal(lhs: List[UInt8], rhs: List[UInt8]) raises:
    assert_equal(len(lhs), len(rhs))
    for index in range(len(lhs)):
        assert_equal(lhs[index], rhs[index])


def _corrupt_last_byte(path: String) raises -> List[UInt8]:
    var bytes = read_file_bytes(path)
    bytes[len(bytes) - 1] ^= UInt8(1)
    write_file_sync(path, bytes)
    return bytes^


def _assert_lock_released(path: String) raises:
    var lock = CollectionLock.acquire(path + "/collection.lock")
    lock.close()


def _non_default_config(dimension: Int) -> CollectionConfig:
    return CollectionConfig(
        dimension=dimension,
        ann_metric=MetricKind.cosine(),
        scalar_kind=ScalarKind.f16(),
        m=12,
        m0=24,
        ef_construction=96,
        default_ef_search=40,
        max_ef_search=320,
        max_level=24,
        rebuild_inactive_percent=30,
        delta_max_points=4096,
        level_seed=UInt64(0x123456789ABCDEF0),
    )


def _assert_config_rejected_without_rewrite(
    path: String,
    requested: CollectionConfig,
    expected_bytes: List[UInt8],
) raises:
    with assert_raises():
        _ = PersistentCollection.open_with_config(path, requested)
    var remaining = read_file_bytes(path + "/collection.bin")
    _assert_bytes_equal(remaining, expected_bytes)


def test_new_two_argument_open_publishes_default_identity_immediately() raises:
    var path = _test_directory("new-default")
    _reset(path)
    assert_equal(collection_config_exists(path), False)
    assert_equal(path_exists(path + "/wal.bin"), False)

    var collection = PersistentCollection.open(path, 3)

    assert_true(collection_config_exists(path))
    assert_equal(path_exists(path + "/wal.bin"), False)
    assert_equal(load_collection_config(path), CollectionConfig.defaults(3))
    assert_equal(collection.dimension, 3)
    assert_equal(collection.ann_metric(), MetricKind.l2())
    assert_equal(collection.collection_config(), CollectionConfig.defaults(3))
    collection.close()


def test_open_with_config_persists_every_field_and_reopens() raises:
    var path = _test_directory("explicit")
    _reset(path)
    var requested = _non_default_config(7)

    var collection = PersistentCollection.open_with_config(path, requested)
    assert_equal(collection.collection_config(), requested)
    assert_equal(collection.ann_metric(), MetricKind.cosine())
    assert_equal(collection.dimension, 7)
    assert_equal(load_collection_config(path), requested)

    # Accessors return a copy and cannot mutate the durable collection identity.
    var returned = collection.collection_config()
    returned.dimension = 99
    returned.m = 2
    assert_equal(collection.collection_config(), requested)
    collection.close()

    var reopened = PersistentCollection.open_with_config(path, requested)
    assert_equal(reopened.collection_config(), requested)
    reopened.close()


def test_existing_identity_rejects_every_immutable_field_mismatch() raises:
    var path = _test_directory("mismatches")
    _reset(path)
    var original = CollectionConfig.defaults(3)
    var collection = PersistentCollection.open_with_config(path, original)
    collection.upsert(7, [1.0, 2.0, 3.0])
    collection.close()
    var config_bytes = read_file_bytes(path + "/collection.bin")

    var changed = original.copy()
    changed.dimension = 4
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.ann_metric = MetricKind.cosine()
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.scalar_kind = ScalarKind.bf16()
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.m = 17
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.m0 = 33
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.ef_construction = 129
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.default_ef_search = 65
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.max_ef_search = 513
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.max_level = 31
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.rebuild_inactive_percent = 26
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.delta_max_points = 10_001
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)
    changed = original.copy()
    changed.level_seed += 1
    _assert_config_rejected_without_rewrite(path, changed, config_bytes)

    # Each failed open released its local lock and preserved authoritative data.
    var reopened = PersistentCollection.open_with_config(path, original)
    assert_equal(reopened.get(7).value().vector[2], Float32(3.0))
    reopened.close()


def test_config_mismatch_reports_field_and_both_fingerprints() raises:
    var path = _test_directory("mismatch-message")
    _reset(path)
    var persisted = CollectionConfig.defaults(3)
    var collection = PersistentCollection.open_with_config(path, persisted)
    collection.close()
    var requested = persisted.copy()
    requested.ann_metric = MetricKind.cosine()
    var message = String()

    try:
        _ = PersistentCollection.open_with_config(path, requested)
    except error:
        message = String(error)

    assert_equal(
        message,
        String(
            "collection configuration mismatch: ann_metric",
            " persisted_fingerprint=",
            persisted.fingerprint(),
            " requested_fingerprint=",
            requested.fingerprint(),
        ),
    )


def test_wal_only_legacy_migration_preserves_wal_and_recovers_records() raises:
    var path = _test_directory("legacy-wal")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(11, [1.0, 2.0])
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_wal = read_file_bytes(path + "/wal.bin")

    var migrated = PersistentCollection.open(path, 2)

    assert_equal(load_collection_config(path), CollectionConfig.defaults(2))
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), before_wal)
    assert_equal(migrated.get(11).value().vector[1], Float32(2.0))
    assert_equal(migrated.last_sequence(), UInt64(1))
    migrated.close()


def test_snapshot_legacy_migration_preserves_all_authoritative_bytes() raises:
    var path = _test_directory("legacy-snapshot")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(1, [1.0, 0.0])
    legacy.flush()
    legacy.upsert(2, [0.0, 2.0])
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_manifest = read_file_bytes(path + "/manifest.bin")
    var before_segment = read_file_bytes(path + "/segment-base-1.bin")
    var before_wal = read_file_bytes(path + "/wal.bin")

    var migrated = PersistentCollection.open(path, 2)

    assert_equal(load_collection_config(path), CollectionConfig.defaults(2))
    _assert_bytes_equal(
        read_file_bytes(path + "/manifest.bin"), before_manifest
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/segment-base-1.bin"), before_segment
    )
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), before_wal)
    assert_equal(migrated.get(1).value().vector[0], Float32(1.0))
    assert_equal(migrated.get(2).value().vector[1], Float32(2.0))
    migrated.close()


def test_wrong_dimension_does_not_poison_wal_only_legacy_identity() raises:
    var path = _test_directory("legacy-wal-wrong-dimension")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(21, [1.0, 2.0])
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_wal = read_file_bytes(path + "/wal.bin")

    with assert_raises():
        _ = PersistentCollection.open(path, 3)

    assert_equal(collection_config_exists(path), False)
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), before_wal)
    var compatible = PersistentCollection.open(path, 2)
    assert_equal(load_collection_config(path), CollectionConfig.defaults(2))
    assert_equal(compatible.get(21).value().vector[1], Float32(2.0))
    compatible.close()


def test_wrong_dimension_does_not_poison_snapshot_legacy_identity() raises:
    var path = _test_directory("legacy-snapshot-wrong-dimension")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(31, [3.0, 1.0])
    legacy.flush()
    # Retain a complete post-checkpoint WAL record as a second identity source.
    legacy.upsert(32, [4.0, 2.0])
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_manifest = read_file_bytes(path + "/manifest.bin")
    var before_segment = read_file_bytes(path + "/segment-base-1.bin")
    var before_wal = read_file_bytes(path + "/wal.bin")

    with assert_raises():
        _ = PersistentCollection.open(path, 3)

    assert_equal(collection_config_exists(path), False)
    _assert_bytes_equal(
        read_file_bytes(path + "/manifest.bin"), before_manifest
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/segment-base-1.bin"), before_segment
    )
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), before_wal)
    var compatible = PersistentCollection.open(path, 2)
    assert_equal(load_collection_config(path), CollectionConfig.defaults(2))
    assert_equal(compatible.get(31).value().vector[0], Float32(3.0))
    assert_equal(compatible.get(32).value().vector[1], Float32(2.0))
    compatible.close()


def test_corrupt_legacy_segment_fails_before_config_publication() raises:
    var path = _test_directory("legacy-corrupt-segment")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(41, [1.0, 4.0])
    legacy.flush()
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_manifest = read_file_bytes(path + "/manifest.bin")
    var corrupt_segment = _corrupt_last_byte(path + "/segment-base-1.bin")
    var before_wal = read_file_bytes(path + "/wal.bin")

    with assert_raises():
        _ = PersistentCollection.open(path, 2)

    assert_equal(collection_config_exists(path), False)
    _assert_bytes_equal(
        read_file_bytes(path + "/manifest.bin"), before_manifest
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/segment-base-1.bin"), corrupt_segment
    )
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), before_wal)
    _assert_lock_released(path)


def test_corrupt_legacy_sparse_snapshot_fails_before_config_publication(
) raises:
    var path = _test_directory("legacy-corrupt-sparse-snapshot")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(51, [1.0, 5.0])
    legacy.upsert_sparse(51, [SparseElement(7, 2.0)])
    legacy.flush()
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_manifest = read_file_bytes(path + "/manifest.bin")
    var before_segment = read_file_bytes(path + "/segment-base-2.bin")
    var corrupt_sparse = _corrupt_last_byte(path + "/sparse-base-2.bin")
    var before_wal = read_file_bytes(path + "/wal.bin")

    with assert_raises():
        _ = PersistentCollection.open(path, 2)

    assert_equal(collection_config_exists(path), False)
    _assert_bytes_equal(
        read_file_bytes(path + "/manifest.bin"), before_manifest
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/segment-base-2.bin"), before_segment
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/sparse-base-2.bin"), corrupt_sparse
    )
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), before_wal)
    _assert_lock_released(path)


def test_corrupt_legacy_sparse_wal_fails_before_config_publication() raises:
    var path = _test_directory("legacy-corrupt-sparse-wal")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(61, [1.0, 6.0])
    legacy.upsert_sparse(61, [SparseElement(8, 3.0)])
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_wal = read_file_bytes(path + "/wal.bin")
    var corrupt_sparse_wal = _corrupt_last_byte(path + "/sparse.wal")

    with assert_raises():
        _ = PersistentCollection.open(path, 2)

    assert_equal(collection_config_exists(path), False)
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), before_wal)
    _assert_bytes_equal(
        read_file_bytes(path + "/sparse.wal"), corrupt_sparse_wal
    )
    _assert_lock_released(path)


def test_corrupt_legacy_dense_delta_blocks_identity_publication() raises:
    var path = _test_directory("legacy-corrupt-dense-delta")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(81, [1.0, 8.0])
    legacy.flush()
    legacy.upsert(82, [2.0, 8.0])
    legacy.flush()
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_manifest = read_file_bytes(path + "/manifest.bin")
    var before_base = read_file_bytes(path + "/segment-base-1.bin")
    var corrupt_delta = _corrupt_last_byte(path + "/segment-delta-2.bin")

    with assert_raises():
        _ = PersistentCollection.open(path, 2)

    assert_equal(collection_config_exists(path), False)
    _assert_bytes_equal(
        read_file_bytes(path + "/manifest.bin"), before_manifest
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/segment-base-1.bin"), before_base
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/segment-delta-2.bin"), corrupt_delta
    )
    _assert_lock_released(path)


def test_late_sparse_delta_failure_does_not_repair_dense_wal() raises:
    var path = _test_directory("legacy-corrupt-sparse-delta")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(91, [1.0, 9.0])
    legacy.upsert_sparse(91, [SparseElement(9, 1.0)])
    legacy.flush()
    legacy.upsert(92, [2.0, 9.0])
    legacy.upsert_sparse(92, [SparseElement(10, 2.0)])
    legacy.flush()
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")

    var before_manifest = read_file_bytes(path + "/manifest.bin")
    var before_dense_delta = read_file_bytes(path + "/segment-delta-4.bin")
    var corrupt_sparse_delta = _corrupt_last_byte(
        path + "/sparse-delta-4.bin"
    )
    # This is an accepted torn dense-WAL suffix. Recovery may identify it
    # during preflight, but must not repair it before later sparse validation.
    var torn_wal = read_file_bytes(path + "/wal.bin")
    torn_wal.append(UInt8(0x41))
    torn_wal.append(UInt8(0x4B))
    torn_wal.append(UInt8(0x57))
    write_file_sync(path + "/wal.bin", torn_wal)

    with assert_raises():
        _ = PersistentCollection.open(path, 2)

    assert_equal(collection_config_exists(path), False)
    _assert_bytes_equal(
        read_file_bytes(path + "/manifest.bin"), before_manifest
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/segment-delta-4.bin"), before_dense_delta
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/sparse-delta-4.bin"),
        corrupt_sparse_delta,
    )
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), torn_wal)
    _assert_lock_released(path)


def test_late_legacy_preflight_failure_preserves_every_source() raises:
    var path = _test_directory("legacy-late-preflight")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(71, [1.0, 7.0])
    legacy.upsert_sparse(71, [SparseElement(9, 4.0)])
    legacy.flush()
    legacy.upsert(72, [2.0, 7.0])
    legacy.upsert_sparse(72, [SparseElement(10, 5.0)])
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_manifest = read_file_bytes(path + "/manifest.bin")
    var before_segment = read_file_bytes(path + "/segment-base-2.bin")
    var before_sparse_snapshot = read_file_bytes(path + "/sparse-base-2.bin")
    var before_wal = read_file_bytes(path + "/wal.bin")
    before_wal.append(0x41)
    before_wal.append(0x4B)
    before_wal.append(0x57)
    write_file_sync(path + "/wal.bin", before_wal)
    var corrupt_sparse_wal = _corrupt_last_byte(path + "/sparse.wal")

    with assert_raises():
        _ = PersistentCollection.open(path, 2)

    assert_equal(collection_config_exists(path), False)
    _assert_bytes_equal(
        read_file_bytes(path + "/manifest.bin"), before_manifest
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/segment-base-2.bin"), before_segment
    )
    _assert_bytes_equal(
        read_file_bytes(path + "/sparse-base-2.bin"), before_sparse_snapshot
    )
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), before_wal)
    _assert_bytes_equal(
        read_file_bytes(path + "/sparse.wal"), corrupt_sparse_wal
    )
    _assert_lock_released(path)


def test_non_default_config_is_rejected_for_legacy_data_without_mutation(
) raises:
    var path = _test_directory("legacy-incompatible")
    _reset(path)
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(9, [4.0, 5.0])
    legacy.close()
    remove_file_if_exists(path + "/collection.bin")
    var before_wal = read_file_bytes(path + "/wal.bin")

    with assert_raises():
        _ = PersistentCollection.open_with_config(
            path, _non_default_config(2)
        )

    assert_equal(collection_config_exists(path), False)
    _assert_bytes_equal(read_file_bytes(path + "/wal.bin"), before_wal)
    var compatible = PersistentCollection.open(path, 2)
    assert_equal(compatible.get(9).value().vector[0], Float32(4.0))
    assert_equal(load_collection_config(path), CollectionConfig.defaults(2))
    compatible.close()


def test_invalid_config_has_no_side_effect_and_does_not_hold_lock() raises:
    var path = _test_directory("invalid")
    # Do not create the directory: validation must precede every file mutation.
    var invalid = CollectionConfig.defaults(3)
    invalid.m = 1

    with assert_raises():
        _ = PersistentCollection.open_with_config(path, invalid)

    assert_equal(path_exists(path), False)
    assert_equal(collection_config_exists(path), False)
    assert_equal(path_exists(path + "/collection.lock"), False)
    assert_equal(path_exists(path + "/wal.bin"), False)
    var valid = PersistentCollection.open(path, 3)
    assert_equal(valid.last_sequence(), UInt64(0))
    valid.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
