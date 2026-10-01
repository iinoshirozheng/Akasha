from akasha import CollectionConfig, PersistentCollection
from akasha.document.vector_schema import legacy_vector_fields
from akasha.storage.filesystem import read_file_bytes, write_file_sync
from akasha.storage.manifest import (
    Manifest,
    SegmentDescriptor,
    load_manifest,
    publish_manifest,
)
from akasha.index.hnsw_rebuild import HnswRebuild
from akasha.index.segmented_hnsw import SegmentedHnsw
from std.memory import ArcPointer
from std.python import Python
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)


def _exercise_publication(base_mode: Int) raises:
    var py = Python.import_module("tempfile")
    var shutil = Python.import_module("shutil")
    var root = String(py=py.mkdtemp(prefix="akasha-base-crash-"))
    for point_mode in [False, True]:
        var path = root + ("/point" if point_mode else "/legacy")
        var config = CollectionConfig.defaults(1)
        var source = PersistentCollection.open_with_fields(
            path, legacy_vector_fields(config), maintenance_library_path=""
        ) if point_mode else PersistentCollection.open_with_config(
            path, config, maintenance_library_path=""
        )
        for id in range(16):
            source.upsert(id, [Float32(id)])
        source.flush()
        if base_mode == 2:
            var current = load_manifest(path, 1)
            var legacy_name = String("hnsw-", current.last_sequence, ".bin")
            write_file_sync(
                path + "/" + legacy_name,
                read_file_bytes(path + "/" + current.hnsw_name.value()),
            )
            var segments = List[SegmentDescriptor]()
            for index in range(len(current.segments)):
                segments.append(current.segments[index].clone())
            source.close()
            var legacy = Manifest.with_hnsw(
                1,
                current.generation,
                current.last_sequence,
                segments^,
                legacy_name,
                current.hnsw_checksum.value(),
                current.hnsw_config_fingerprint.value(),
                current.hnsw_point_count.value(),
            )
            publish_manifest(path, legacy)
            source = PersistentCollection.open_with_config(
                path, config, maintenance_library_path=""
            )
        var old_manifest = read_file_bytes(path + "/manifest.bin")
        var base_name = load_manifest(path, 1).hnsw_name.value().copy()
        var old_base_name = base_name.copy()
        var old_base_bytes = read_file_bytes(path + "/" + old_base_name)
        var job = Optional[ArcPointer[HnswRebuild]]()
        var candidate = Optional[SegmentedHnsw]()
        if base_mode == 1:
            job = Optional(source._begin_hnsw_rebuild())
            candidate = Optional(job.value()[].build())
        source.upsert(0, [50.0])
        source.delete(1)
        source.upsert(20, [20.0])
        var wal = read_file_bytes(path + "/wal.bin")
        if base_mode == 1:
            assert_true(
                source._finish_hnsw_rebuild(job.value(), candidate.take())
            )
        source.flush()
        var committed = read_file_bytes(path + "/manifest.bin")
        base_name = load_manifest(path, 1).hnsw_name.value().copy()
        assert_equal(load_manifest(path, 1).format_version, 5)
        source.close()
        for boundary in range(6):
            var target = path + "-" + String(boundary)
            shutil.copytree(path, target)
            if boundary == 0 or boundary == 4:
                write_file_sync(target + "/manifest.bin", old_manifest)
                write_file_sync(target + "/" + old_base_name, old_base_bytes)
            if boundary < 2 or boundary >= 4:
                write_file_sync(target + "/wal.bin", wal)
            if boundary == 4:
                write_file_sync(target + "/manifest.bin.tmp", committed)
            if boundary == 5:
                var torn = wal.copy()
                torn.append(UInt8(0x41))
                torn.append(UInt8(0x4B))
                write_file_sync(target + "/wal.bin", torn)
                var corrupt = read_file_bytes(target + "/" + base_name)
                corrupt[40] ^= 1
                write_file_sync(target + "/" + base_name, corrupt)
                with assert_raises():
                    _ = PersistentCollection.open(target, 1)
                assert_equal(read_file_bytes(target + "/wal.bin"), torn)
                continue
            var recovered = PersistentCollection.open_with_config(
                target, config, maintenance_library_path=""
            )
            assert_equal(recovered.last_sequence(), UInt64(19))
            assert_true(recovered._hnsw.base_is_mapped())
            assert_equal(recovered._hnsw.base_slot_count(), 16)
            assert_equal(recovered._hnsw.delta_slot_count(), 2)
            assert_equal(recovered.get(0).value().vector[0], Float32(50))
            assert_false(recovered.get(1))
            assert_true(recovered.get(20))
            recovered.upsert(21, [21.0])
            recovered.flush()
            recovered.close()
            var again = PersistentCollection.open_with_config(
                target, config, maintenance_library_path=""
            )
            assert_true(again.get(21))
            assert_true(again._hnsw.base_is_mapped())
            again.close()
    shutil.rmtree(root)


def test_retained_base_checkpoint_windows_and_corruption_before_wal_repair() raises:
    _exercise_publication(0)


def test_caught_up_rebuild_publication_windows() raises:
    _exercise_publication(1)


def test_v3_base_name_migration_publication_windows() raises:
    _exercise_publication(2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
