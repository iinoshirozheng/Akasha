from akasha import PersistentCollection, SparseElement
from akasha.api.batch import BatchMutation
from akasha.storage.field_catalog import load_field_catalog
from akasha.storage.filesystem import ensure_directory
from akasha.storage.wal import WalRecord, append_wal
from akasha.storage.sparse_store import SparseWalRecord, append_sparse_wal
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_true, TestSuite


def _path(suffix: String) -> String:
    return String("/tmp/akasha-default-point-alignment-", Int(external_call["getpid", c_int]()), "-", suffix)


def test_default_open_uses_atomic_point_replacement_live_and_reopen() raises:
    var path = _path("replace")
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1, 2])
    collection.upsert_sparse(1, [SparseElement(9, 3)])
    collection.upsert(1, [4, 5])
    assert_equal(len(collection.search_sparse_dot([SparseElement(9, 1)], 10)), 0)
    collection.upsert_sparse(1, [SparseElement(9, 4)])
    _ = collection.apply_batch([BatchMutation.upsert(1, [6, 7])])
    assert_equal(len(collection.search_sparse_dot([SparseElement(9, 1)], 10)), 0)
    collection.close()
    var reopened = PersistentCollection.open(path, 2)
    assert_equal(len(reopened.search_sparse_dot([SparseElement(9, 1)], 10)), 0)
    assert_equal(load_field_catalog(path).format_version, 2)
    reopened.flush()
    reopened.close()
    var checkpointed = PersistentCollection.open(path, 2)
    assert_equal(len(checkpointed.search_sparse_dot([SparseElement(9, 1)], 10)), 0)
    checkpointed.close()


def test_default_open_migrates_legacy_merge_before_new_replacement() raises:
    var path = _path("legacy")
    ensure_directory(path)
    append_wal(path + "/wal.bin", 2, WalRecord.upsert(1, 1, [1, 2]))
    append_sparse_wal(path + "/sparse.wal", SparseWalRecord.upsert(2, 1, [SparseElement(9, 3)]))
    append_wal(path + "/wal.bin", 2, WalRecord.upsert(3, 1, [4, 5]))
    var collection = PersistentCollection.open(path, 2)
    # Historical upsert merged: migration preserves that committed state.
    assert_equal(collection.search_sparse_dot([SparseElement(9, 1)], 10)[0].score, Float32(3))
    assert_equal(load_field_catalog(path).legacy_cutover_sequence, UInt64(3))
    collection.upsert(1, [6, 7])
    assert_equal(len(collection.search_sparse_dot([SparseElement(9, 1)], 10)), 0)
    collection.close()
    var reopened = PersistentCollection.open(path, 2)
    assert_equal(len(reopened.search_sparse_dot([SparseElement(9, 1)], 10)), 0)
    assert_equal(reopened.last_sequence(), UInt64(4))
    reopened.close()


def test_default_sparse_empty_and_zero_remain_present_after_checkpoint() raises:
    var path = _path("sparse")
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1, 2])
    collection.upsert_sparse(1, List[SparseElement]())
    assert_true(collection.get_point(1).value().ordinal_for(1) >= 0)
    assert_equal(len(collection.search_sparse_dot(List[SparseElement](), 10)), 0)
    collection.upsert_sparse(1, [SparseElement(9, 0)])
    assert_equal(len(collection.search_sparse_dot([SparseElement(9, 1)], 10)), 0)
    collection.flush()
    collection.close()
    var reopened = PersistentCollection.open(path, 2)
    assert_equal(reopened.get_point(1).value().field_at(1).value().sparse_values()[0].weight, Float32(0))
    reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
