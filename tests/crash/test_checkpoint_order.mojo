from akasha import PersistentCollection, SparseElement
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from std.os import listdir
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def test_manifest_publish_before_wal_rotation_recovers_once() raises:
    var directory = String("/tmp/akasha-phase5-crash-checkpoint")
    ensure_directory(directory)
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/wal.bin.tmp")
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    remove_file_if_exists(directory + "/segment-1.bin")

    var collection = PersistentCollection.open(directory, 1)
    collection.upsert(42, [4.0])
    var pre_checkpoint_wal = read_file_bytes(directory + "/wal.bin")
    collection.flush()

    # Simulate power loss after manifest durability but before WAL replacement.
    write_file_sync(directory + "/wal.bin", pre_checkpoint_wal)
    collection.close()

    var recovered = PersistentCollection.open(directory, 1)
    var results = recovered.search_dot([1.0], 2)
    assert_equal(len(results), 1)
    assert_equal(results[0].id, 42)
    assert_equal(recovered.last_sequence(), UInt64(1))


def _cache_names() -> List[String]:
    return ["metadata.cache", "hnsw.cache"]


struct _CompactionFixture(Movable):
    var old_manifest: List[UInt8]
    var new_manifest: List[UInt8]
    var old_generation: UInt64
    var old_caches: List[List[UInt8]]
    var input_names: List[String]
    var inputs: List[List[UInt8]]
    var output_names: List[String]

    def __init__(
        out self,
        var old_manifest: List[UInt8],
        var new_manifest: List[UInt8],
        old_generation: UInt64,
        var old_caches: List[List[UInt8]],
        var input_names: List[String],
        var inputs: List[List[UInt8]],
        var output_names: List[String],
    ):
        self.old_manifest = old_manifest^
        self.new_manifest = new_manifest^
        self.old_generation = old_generation
        self.old_caches = old_caches^
        self.input_names = input_names^
        self.inputs = inputs^
        self.output_names = output_names^

    def restore_inputs(self, path: String, count: Int) raises:
        for index in range(count):
            write_file_sync(
                path + "/" + self.input_names[index], self.inputs[index]
            )

    def restore_old_caches(self, path: String) raises:
        var names = _cache_names()
        for index in range(len(names)):
            var cache = path + "/" + names[index]
            if len(self.old_caches[index]) == 0:
                remove_file_if_exists(cache)
            else:
                write_file_sync(cache, self.old_caches[index])


def _prepare_compaction(path: String) raises -> _CompactionFixture:
    """Run one compaction whose build overlaps WAL-only writes 81..83."""
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)
    var collection = PersistentCollection.open(path, 1)
    for id in range(1, 21):
        collection.upsert(id, [Float32(id)])
        collection.upsert_sparse(id, [SparseElement(id, Float32(id))])
    collection.flush()
    for id in range(21, 41):
        collection.upsert(id, [Float32(id)])
        collection.upsert_sparse(id, [SparseElement(id, Float32(id))])
    collection.flush()

    var old_manifest = read_file_bytes(path + "/manifest.bin")
    var committed = load_manifest(path, 1)
    var input_names = List[String]()
    var inputs = List[List[UInt8]]()
    for index in range(len(committed.segments)):
        input_names.append(committed.segments[index].name.copy())
        input_names.append(committed.segments[index].sparse_name.copy())
    for name in input_names:
        inputs.append(read_file_bytes(path + "/" + name))
    var old_caches = List[List[UInt8]]()
    for name in _cache_names():
        if path_exists(path + "/" + name):
            old_caches.append(read_file_bytes(path + "/" + name))
        else:
            old_caches.append(List[UInt8]())

    var job = collection._begin_compaction()
    collection.upsert(41, [41.0])
    collection.upsert_sparse(41, [SparseElement(41, 41.0)])
    var output = collection._build_compaction(job.value())
    collection.delete(1)
    assert_true(collection._finish_compaction(job.value(), output))
    var new_manifest = read_file_bytes(path + "/manifest.bin")
    collection.close()
    var output_names: List[String] = [output.segment_name, output.sparse_name]
    return _CompactionFixture(
        old_manifest^,
        new_manifest^,
        committed.generation,
        old_caches^,
        input_names^,
        inputs^,
        output_names^,
    )


def _assert_compaction_recovered(path: String, generation: UInt64) raises:
    var recovered = PersistentCollection.open(path, 1)
    assert_equal(recovered.last_sequence(), UInt64(83))
    assert_equal(load_manifest(path, 1).generation, generation)
    var snapshot = recovered.snapshot()
    assert_equal(snapshot.generation(), generation)
    snapshot.close()
    assert_false(Bool(recovered.get(1)))
    for id in range(2, 42):
        var record = recovered.get(id)
        assert_true(Bool(record))
        assert_equal(record.value().vector[0], Float32(id))
        var sparse = recovered.search_sparse_dot([SparseElement(id, 1.0)], 1)
        assert_equal(len(sparse), 1)
        assert_equal(sparse[0].id, id)
    recovered.close()


def test_compaction_output_fsync_boundary_recovers_old_generation() raises:
    var path = String("/tmp/akasha-51-crash-output-fsync")
    var fixture = _prepare_compaction(path)
    # Outputs are durable but no manifest names them yet.
    write_file_sync(path + "/manifest.bin", fixture.old_manifest)
    fixture.restore_inputs(path, len(fixture.input_names))
    fixture.restore_old_caches(path)
    _assert_compaction_recovered(path, fixture.old_generation)
    for name in fixture.output_names:
        assert_false(path_exists(path + "/" + name))


def test_compaction_manifest_temporary_boundary_recovers_old_generation() raises:
    var path = String("/tmp/akasha-51-crash-manifest-temporary")
    var fixture = _prepare_compaction(path)
    write_file_sync(path + "/manifest.bin", fixture.old_manifest)
    write_file_sync(path + "/manifest.bin.tmp", fixture.new_manifest)
    fixture.restore_inputs(path, len(fixture.input_names))
    fixture.restore_old_caches(path)
    _assert_compaction_recovered(path, fixture.old_generation)
    for name in fixture.output_names:
        assert_false(path_exists(path + "/" + name))


def test_compaction_manifest_publish_boundary_recovers_new_generation() raises:
    var path = String("/tmp/akasha-51-crash-manifest-publish")
    var fixture = _prepare_compaction(path)
    # Durable manifest before the root swap and derived-cache publication.
    fixture.restore_inputs(path, len(fixture.input_names))
    fixture.restore_old_caches(path)
    _assert_compaction_recovered(path, fixture.old_generation + 1)
    for name in fixture.output_names:
        assert_true(path_exists(path + "/" + name))


def test_compaction_root_swap_boundary_recovers_new_generation() raises:
    var path = String("/tmp/akasha-51-crash-root-swap")
    var fixture = _prepare_compaction(path)
    # Root and caches moved to the new generation; inputs are not retired.
    fixture.restore_inputs(path, len(fixture.input_names))
    _assert_compaction_recovered(path, fixture.old_generation + 1)


def test_compaction_cleanup_boundary_recovers_new_generation() raises:
    var path = String("/tmp/akasha-51-crash-cleanup")
    var fixture = _prepare_compaction(path)
    # Retirement unlinked only part of the replaced input set.
    fixture.restore_inputs(path, 1)
    _assert_compaction_recovered(path, fixture.old_generation + 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
