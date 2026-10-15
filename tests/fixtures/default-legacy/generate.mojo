# Compile only against source commit f6a938a, not the current writer.
from akasha import PersistentCollection, SparseElement

def seed_0() raises:
    var path = String("tests/fixtures/default-legacy/config-wal_only_legacy_migration_preserves_wal_and_recovers_records")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(11, [1.0, 2.0])
    legacy.close()

def seed_1() raises:
    var path = String("tests/fixtures/default-legacy/config-snapshot_legacy_migration_preserves_all_authoritative_bytes")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(1, [1.0, 0.0])
    legacy.flush()
    legacy.upsert(2, [0.0, 2.0])
    legacy.close()

def seed_2() raises:
    var path = String("tests/fixtures/default-legacy/config-wrong_dimension_does_not_poison_wal_only_legacy_identity")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(21, [1.0, 2.0])
    legacy.close()

def seed_3() raises:
    var path = String("tests/fixtures/default-legacy/config-wrong_dimension_does_not_poison_snapshot_legacy_identity")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(31, [3.0, 1.0])
    legacy.flush()
    # Retain a complete post-checkpoint WAL record as a second identity source.
    legacy.upsert(32, [4.0, 2.0])
    legacy.close()

def seed_4() raises:
    var path = String("tests/fixtures/default-legacy/config-corrupt_legacy_segment_fails_before_config_publication")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(41, [1.0, 4.0])
    legacy.flush()
    legacy.close()

def seed_5() raises:
    var path = String("tests/fixtures/default-legacy/config-corrupt_legacy_sparse_snapshot_fails_before_config_publication")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(51, [1.0, 5.0])
    legacy.upsert_sparse(51, [SparseElement(7, 2.0)])
    legacy.flush()
    legacy.close()

def seed_6() raises:
    var path = String("tests/fixtures/default-legacy/config-corrupt_legacy_sparse_wal_fails_before_config_publication")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(61, [1.0, 6.0])
    legacy.upsert_sparse(61, [SparseElement(8, 3.0)])
    legacy.close()

def seed_7() raises:
    var path = String("tests/fixtures/default-legacy/config-corrupt_legacy_dense_delta_blocks_identity_publication")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(81, [1.0, 8.0])
    legacy.flush()
    legacy.upsert(82, [2.0, 8.0])
    legacy.flush()
    legacy.close()

def seed_8() raises:
    var path = String("tests/fixtures/default-legacy/config-late_sparse_delta_failure_does_not_repair_dense_wal")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(91, [1.0, 9.0])
    legacy.upsert_sparse(91, [SparseElement(9, 1.0)])
    legacy.flush()
    legacy.upsert(92, [2.0, 9.0])
    legacy.upsert_sparse(92, [SparseElement(10, 2.0)])
    legacy.flush()
    legacy.close()

def seed_9() raises:
    var path = String("tests/fixtures/default-legacy/config-late_legacy_preflight_failure_preserves_every_source")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(71, [1.0, 7.0])
    legacy.upsert_sparse(71, [SparseElement(9, 4.0)])
    legacy.flush()
    legacy.upsert(72, [2.0, 7.0])
    legacy.upsert_sparse(72, [SparseElement(10, 5.0)])
    legacy.close()

def seed_10() raises:
    var path = String("tests/fixtures/default-legacy/config-non_default_config_is_rejected_for_legacy_data_without_mutation")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(9, [4.0, 5.0])
    legacy.close()

def seed_11() raises:
    var path = String("tests/fixtures/default-legacy/store-legacy_upgrade_first_checkpoint_replaces_legacy_segments_and_keeps_versions")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(1, [1, 2])
    legacy.upsert_sparse(1, [SparseElement(2, 3)])
    legacy.flush()
    legacy.close()

def seed_12() raises:
    var path = String("tests/fixtures/default-legacy/named-public_migration_and_invalid_late_field_leave_wal_unchanged")
    var legacy = PersistentCollection.open(path, 2)
    legacy.upsert(1, [1, 2])
    legacy.upsert_sparse(1, [SparseElement(1, 1)])
    legacy.flush()
    legacy.close()

def seed_13() raises:
    var path = String("tests/fixtures/default-legacy/recovery-preflight_replays_checkpoint_and_both_wals_without_repair_or_publication")
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1, 2])
    collection.upsert_sparse(1, [SparseElement(8, 3)])
    collection.flush()
    collection.upsert(2, [3, 4])
    collection.upsert_sparse(2, [SparseElement(9, 5)])
    collection.delete(1)
    collection.upsert(1, [6, 7])
    var last = collection.last_sequence()
    collection.close()

def seed_14() raises:
    var path = String("tests/fixtures/default-legacy/recovery-late_corrupt_sparse_source_leaves_dense_tail_and_identity_untouched")
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1, 2])
    collection.upsert_sparse(1, [SparseElement(1, 2)])
    collection.close()

def seed_15() raises:
    var path = String("tests/fixtures/default-legacy/point-cutover-0")
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1, 2])
    collection.upsert_sparse(1, [SparseElement(9, 3)])
    collection.upsert(2, [4, 5])

    collection.delete(2)
    collection.upsert(2, [6, 7])
    collection.upsert_sparse(2, [SparseElement(8, 2)])
    collection.close()

def seed_16() raises:
    var path = String("tests/fixtures/default-legacy/point-cutover-1")
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1, 2])
    collection.upsert_sparse(1, [SparseElement(9, 3)])
    collection.upsert(2, [4, 5])
    collection.flush()
    collection.delete(2)
    collection.upsert(2, [6, 7])
    collection.upsert_sparse(2, [SparseElement(8, 2)])
    collection.close()


def main() raises:
    seed_0()
    seed_1()
    seed_2()
    seed_3()
    seed_4()
    seed_5()
    seed_6()
    seed_7()
    seed_8()
    seed_9()
    seed_10()
    seed_11()
    seed_12()
    seed_13()
    seed_14()
    seed_15()
    seed_16()
