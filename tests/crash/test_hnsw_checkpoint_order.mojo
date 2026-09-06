from akasha import CollectionConfig, PersistentCollection, SparseElement
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from std.testing import assert_equal, assert_true, TestSuite


struct _CheckpointFixture(Movable):
    var old_manifest: List[UInt8]
    var new_manifest: List[UInt8]
    var retained_wal: List[UInt8]
    var retained_sparse_wal: List[UInt8]
    var old_hnsw_name: String
    var old_hnsw: List[UInt8]
    var new_dense_name: String
    var new_sparse_name: String
    var new_hnsw_name: String
    var new_dense: List[UInt8]
    var new_sparse: List[UInt8]
    var new_hnsw: List[UInt8]

    def __init__(
        out self,
        var old_manifest: List[UInt8],
        var new_manifest: List[UInt8],
        var retained_wal: List[UInt8],
        var retained_sparse_wal: List[UInt8],
        old_hnsw_name: String,
        var old_hnsw: List[UInt8],
        new_dense_name: String,
        new_sparse_name: String,
        new_hnsw_name: String,
        var new_dense: List[UInt8],
        var new_sparse: List[UInt8],
        var new_hnsw: List[UInt8],
    ):
        self.old_manifest = old_manifest^
        self.new_manifest = new_manifest^
        self.retained_wal = retained_wal^
        self.retained_sparse_wal = retained_sparse_wal^
        self.old_hnsw_name = String(copy=old_hnsw_name)
        self.old_hnsw = old_hnsw^
        self.new_dense_name = String(copy=new_dense_name)
        self.new_sparse_name = String(copy=new_sparse_name)
        self.new_hnsw_name = String(copy=new_hnsw_name)
        self.new_dense = new_dense^
        self.new_sparse = new_sparse^
        self.new_hnsw = new_hnsw^


def _reset(path: String) raises:
    ensure_directory(path)
    for name in [
        "wal.bin",
        "wal.bin.tmp",
        "sparse.wal",
        "sparse.wal.tmp",
        "manifest.bin",
        "manifest.bin.tmp",
        "collection.bin",
        "collection.bin.tmp",
        "collection.lock",
    ]:
        remove_file_if_exists(path + "/" + name)
    for sequence in range(256):
        for prefix in [
            "segment-base-",
            "segment-delta-",
            "sparse-base-",
            "sparse-delta-",
            "hnsw-",
        ]:
            remove_file_if_exists(
                path + "/" + prefix + String(sequence) + ".bin"
            )
            remove_file_if_exists(
                path + "/" + prefix + String(sequence) + ".bin.tmp"
            )


def _prepare(path: String) raises -> _CheckpointFixture:
    _reset(path)
    var config = CollectionConfig.defaults(1)
    var collection = PersistentCollection.open_with_config(path, config.copy())
    for id in range(1, 81):
        collection.upsert(id, [Float32(id)])
        collection.upsert_sparse(
            id, [SparseElement(id, Float32(id))]
        )
    collection.flush()
    var old_committed = load_manifest(path, 1)
    var old_hnsw_name = old_committed.hnsw_name.value().copy()
    var old_manifest = read_file_bytes(path + "/manifest.bin")
    var old_hnsw = read_file_bytes(path + "/" + old_hnsw_name)

    collection.upsert(81, [81.0])
    collection.upsert_sparse(81, [SparseElement(81, 81.0)])
    var retained_wal = read_file_bytes(path + "/wal.bin")
    var retained_sparse_wal = read_file_bytes(path + "/sparse.wal")
    collection.rebuild_hnsw()
    collection.flush()
    var committed = load_manifest(path, 1)
    var newest = len(committed.segments) - 1
    var new_dense_name = committed.segments[newest].name.copy()
    var new_sparse_name = committed.segments[newest].sparse_name.copy()
    var new_hnsw_name = committed.hnsw_name.value().copy()
    var new_dense = read_file_bytes(path + "/" + new_dense_name)
    var new_sparse = read_file_bytes(path + "/" + new_sparse_name)
    var new_hnsw = read_file_bytes(path + "/" + new_hnsw_name)
    var new_manifest = read_file_bytes(path + "/manifest.bin")
    collection.close()
    return _CheckpointFixture(
        old_manifest^,
        new_manifest^,
        retained_wal^,
        retained_sparse_wal^,
        old_hnsw_name,
        old_hnsw^,
        new_dense_name,
        new_sparse_name,
        new_hnsw_name,
        new_dense^,
        new_sparse^,
        new_hnsw^,
    )


def _assert_acknowledged_records(path: String) raises:
    var recovered = PersistentCollection.open(path, 1)
    assert_equal(recovered.last_sequence(), UInt64(162))
    assert_equal(recovered.search_dot([1.0], 2)[0].id, 81)
    assert_equal(recovered.search_dot([1.0], 2)[1].id, 80)
    for id in range(1, 82):
        var record = recovered.get(id)
        assert_true(Bool(record))
        assert_equal(record.value().vector[0], Float32(id))
        var sparse = recovered.search_sparse_dot(
            [SparseElement(id, 1.0)], 1
        )
        assert_equal(len(sparse), 1)
        assert_equal(sparse[0].id, id)
    assert_true(recovered.hnsw_available())
    recovered.close()


def test_old_manifest_ignores_unreferenced_data_temporaries() raises:
    var path = String("/tmp/akasha-task22-crash-window-1")
    var fixture = _prepare(path)
    # New immutable files may exist as durable temporaries, but the old
    # manifest remains the commit authority and the retained WAL carries 81.
    write_file_sync(path + "/manifest.bin", fixture.old_manifest)
    write_file_sync(path + "/wal.bin", fixture.retained_wal)
    write_file_sync(path + "/sparse.wal", fixture.retained_sparse_wal)
    remove_file_if_exists(path + "/" + fixture.new_dense_name)
    remove_file_if_exists(path + "/" + fixture.new_sparse_name)
    remove_file_if_exists(path + "/" + fixture.new_hnsw_name)
    write_file_sync(
        path + "/" + fixture.old_hnsw_name, fixture.old_hnsw
    )
    write_file_sync(
        path + "/" + fixture.new_dense_name + ".tmp", fixture.new_dense
    )
    write_file_sync(
        path + "/" + fixture.new_sparse_name + ".tmp", fixture.new_sparse
    )
    write_file_sync(
        path + "/" + fixture.new_hnsw_name + ".tmp", fixture.new_hnsw
    )
    _assert_acknowledged_records(path)


def test_old_manifest_ignores_renamed_unreferenced_data_files() raises:
    var path = String("/tmp/akasha-task22-crash-window-2")
    var fixture = _prepare(path)
    write_file_sync(path + "/manifest.bin", fixture.old_manifest)
    write_file_sync(path + "/wal.bin", fixture.retained_wal)
    write_file_sync(path + "/sparse.wal", fixture.retained_sparse_wal)
    write_file_sync(
        path + "/" + fixture.old_hnsw_name, fixture.old_hnsw
    )
    _assert_acknowledged_records(path)


def test_new_manifest_with_old_wal_recovers_once() raises:
    var path = String("/tmp/akasha-task22-crash-window-3")
    var fixture = _prepare(path)
    write_file_sync(path + "/manifest.bin", fixture.new_manifest)
    write_file_sync(path + "/wal.bin", fixture.retained_wal)
    write_file_sync(path + "/sparse.wal", fixture.retained_sparse_wal)
    write_file_sync(
        path + "/" + fixture.old_hnsw_name, fixture.old_hnsw
    )
    _assert_acknowledged_records(path)


def test_rotated_wal_with_old_sidecar_present_uses_new_commit() raises:
    var path = String("/tmp/akasha-task22-crash-window-4")
    var fixture = _prepare(path)
    write_file_sync(path + "/manifest.bin", fixture.new_manifest)
    write_file_sync(
        path + "/" + fixture.old_hnsw_name, fixture.old_hnsw
    )
    _assert_acknowledged_records(path)


def test_cleanup_boundary_keeps_new_commit_recoverable() raises:
    var path = String("/tmp/akasha-task22-crash-window-5")
    var fixture = _prepare(path)
    write_file_sync(path + "/manifest.bin", fixture.new_manifest)
    remove_file_if_exists(path + "/" + fixture.old_hnsw_name)
    _assert_acknowledged_records(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
