from akasha import PersistentCollection, SparseElement
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    write_file_sync,
)
from akasha.storage.legacy_recovery import preflight_legacy_authority
from std.ffi import c_int, external_call
from std.os import listdir
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def _path(suffix: String) -> String:
    return String(
        "/tmp/akasha-legacy-preflight-",
        Int(external_call["getpid", c_int]()),
        "-",
        suffix,
    )


def _bytes(path: String) raises -> Dict[String, List[UInt8]]:
    var result = Dict[String, List[UInt8]]()
    for name in listdir(path):
        result[name] = read_file_bytes(path + "/" + name)
    return result^


def _unchanged(path: String, before: Dict[String, List[UInt8]]) raises:
    var after = _bytes(path)
    assert_equal(len(before), len(after))
    for item in before.items():
        assert_equal(after[item.key], item.value)


def test_preflight_replays_checkpoint_and_both_wals_without_repair_or_publication() raises:
    var path = _path("mixed")
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
    var wal = read_file_bytes(path + "/wal.bin")
    var accepted_length = len(wal)
    wal.append(0xAA)
    write_file_sync(path + "/wal.bin", wal)
    var before = _bytes(path)
    var result = preflight_legacy_authority(path, 2)
    assert_equal(result.last_sequence, last)
    assert_equal(result.snapshot_sequence, UInt64(2))
    assert_equal(result.wal_valid_length, accepted_length)
    assert_equal(result.wal_source_length, accepted_length + 1)
    assert_equal(result.memtable.value().get(1).value().vector[0], Float32(6))
    assert_false(
        result.memtable.value()
        .entry_ref_at(result.memtable.value().ordinal_for(1))
        .has_sparse()
    )
    assert_true(
        result.memtable.value()
        .entry_ref_at(result.memtable.value().ordinal_for(2))
        .has_sparse()
    )
    assert_true(1 in result.checkpoint_live_ids.value())
    assert_false(2 in result.checkpoint_live_ids.value())
    _unchanged(path, before)


def test_late_corrupt_sparse_source_leaves_dense_tail_and_identity_untouched() raises:
    var path = _path("corrupt")
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1, 2])
    collection.upsert_sparse(1, [SparseElement(1, 2)])
    collection.close()
    var dense = read_file_bytes(path + "/wal.bin")
    dense.append(0xAB)
    write_file_sync(path + "/wal.bin", dense)
    var sparse = read_file_bytes(path + "/sparse.wal")
    sparse[len(sparse) - 1] ^= 1
    write_file_sync(path + "/sparse.wal", sparse)
    var before = _bytes(path)
    with assert_raises():
        _ = preflight_legacy_authority(path, 2)
    _unchanged(path, before)


def test_empty_preflight_does_not_create_identity_lock_or_wal() raises:
    var path = _path("empty")
    ensure_directory(path)
    var result = preflight_legacy_authority(path, 2)
    assert_equal(result.last_sequence, UInt64(0))
    assert_equal(result.memtable.value().live_count(), 0)
    assert_equal(len(listdir(path)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
