from akasha import CollectionConfig, PersistentCollection
from akasha.document.point_state import PointMutation, FieldUpdate
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.storage.filesystem import (
    path_exists,
    read_file_bytes,
    write_file_sync,
)
from akasha.storage.manifest import (
    Manifest,
    SegmentDescriptor,
    load_manifest,
    hnsw_base_sequence,
    publish_manifest,
)
from akasha.storage.operations import restore_storage
from std.python import Python
from std.testing import assert_equal, assert_true, assert_false, TestSuite


def _path() raises -> String:
    return String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-base-replay-"
        )
    )


def test_small_update_checkpoint_retains_mapped_base_without_full_rebuild() raises:
    var path = _path()
    var config = CollectionConfig.defaults(2)
    config.delta_max_points = 1000
    config.rebuild_inactive_percent = 90
    var collection = PersistentCollection.open_with_config(
        path, config, maintenance_library_path=""
    )
    for id in range(80):
        collection.upsert(id, [Float32(id), 1.0])
    collection.flush()
    var original = load_manifest(path, 2)
    var name = original.hnsw_name.value().copy()
    collection.upsert(0, [200.0, 1.0])
    collection.delete(1)
    collection.upsert(90, [90.0, 1.0])
    collection.flush()
    var checkpoint = load_manifest(path, 2)
    assert_equal(checkpoint.format_version, 5)
    assert_equal(checkpoint.hnsw_name.value(), name)
    assert_equal(hnsw_base_sequence(checkpoint), UInt64(80))
    assert_true(path_exists(path + "/" + name))
    collection.close()
    var reopened = PersistentCollection.open_with_config(
        path, config, maintenance_library_path=""
    )
    assert_true(reopened._hnsw_checkpoint_was_hit)
    assert_true(reopened._hnsw.base_is_mapped())
    assert_equal(reopened._hnsw.base_slot_count(), 80)
    assert_equal(reopened._hnsw.delta_slot_count(), 2)
    assert_equal(reopened._hnsw._delta.build_distance_evaluations(), 0)
    assert_equal(reopened._hnsw.current_point_count(), 80)
    assert_false(reopened._hnsw.contains_current(1))
    assert_equal(reopened.search_l2([200.0, 1.0], 1)[0].id, 0)
    _ = reopened.search_l2_approx([200.0, 1.0], 1, 128)
    reopened.upsert(0, [201.0, 1.0])
    reopened.delete(90)
    reopened.upsert(1, [101.0, 1.0])
    reopened.flush()
    reopened.compact()
    assert_equal(load_manifest(path, 2).hnsw_name.value(), name)
    var backup = path + "/backup"
    _ = reopened.backup_to(backup)
    reopened.close()
    _ = restore_storage(backup, path + "/restore", 2)
    var restored = PersistentCollection.open_with_config(
        path + "/restore", config, maintenance_library_path=""
    )
    assert_true(restored._hnsw.base_is_mapped())
    assert_equal(restored._hnsw.delta_slot_count(), 2)
    assert_false(restored._hnsw.contains_current(90))
    assert_true(restored._hnsw.contains_current(1))
    restored.flush()
    restored.close()
    Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()


def test_caught_up_rebuild_persists_its_immutable_base() raises:
    for typed in [False, True]:
        for checkpoint_first in [False, True]:
            for checkpoint_during in [False, True]:
                var path = _path()
                var config = CollectionConfig.defaults(2)
                config.delta_max_points = 1000
                config.rebuild_inactive_percent = 90
                var collection = PersistentCollection.open_with_config(
                    path, config, maintenance_library_path=""
                )
                if typed:
                    collection.close()
                    collection = PersistentCollection.open_with_fields(
                        path,
                        legacy_vector_fields(config),
                        maintenance_library_path="",
                    )
                for id in range(80):
                    collection.upsert(id, [Float32(id), 1.0])
                if checkpoint_first:
                    collection.flush()
                var job = collection._begin_hnsw_rebuild()
                var candidate = job[].build()
                collection.upsert(0, [200.0, 1.0])
                collection.delete(1)
                collection.upsert(99, [99.0, 1.0])
                if checkpoint_during:
                    collection.flush()
                assert_true(collection._finish_hnsw_rebuild(job, candidate^))
                assert_false(collection._hnsw.checkpoint_ready())
                collection.flush()
                var manifest = load_manifest(path, 2)
                assert_true(Bool(manifest.hnsw_name))
                assert_equal(manifest.format_version, 5)
                assert_equal(hnsw_base_sequence(manifest), UInt64(80))
                collection.close()
                var reopened = PersistentCollection.open_with_config(
                    path, config, maintenance_library_path=""
                )
                assert_true(reopened._hnsw_checkpoint_was_hit)
                assert_true(reopened._hnsw.base_is_mapped())
                assert_equal(reopened._hnsw.delta_slot_count(), 2)
                assert_equal(reopened._hnsw.current_point_count(), 80)
                assert_false(reopened._hnsw.contains_current(1))
                assert_equal(
                    reopened.search_l2_approx([200.0, 1.0], 1, 128)[0].id, 0
                )
                reopened.close()
                Python.import_module("shutil").rmtree(path)


def test_v3_small_update_migrates_base_name_without_rebuilding() raises:
    for typed in [False, True]:
        var path = _path()
        var config = CollectionConfig.defaults(2)
        config.delta_max_points = 1000
        config.rebuild_inactive_percent = 90
        var collection = PersistentCollection.open_with_fields(
            path, legacy_vector_fields(config), maintenance_library_path=""
        ) if typed else PersistentCollection.open_with_config(
            path, config, maintenance_library_path=""
        )
        for id in range(80):
            collection.upsert(id, [Float32(id), 1.0])
        collection.flush()
        collection.close()
        var original = load_manifest(path, 2)
        var bytes = read_file_bytes(path + "/" + original.hnsw_name.value())
        var old_name = String("hnsw-80.bin")
        write_file_sync(path + "/" + old_name, bytes)
        var segments = List[SegmentDescriptor]()
        for index in range(len(original.segments)):
            segments.append(original.segments[index].clone())
        var legacy = Manifest.with_hnsw(
            2,
            original.generation,
            original.last_sequence,
            segments^,
            old_name,
            original.hnsw_checksum.value(),
            original.hnsw_config_fingerprint.value(),
            original.hnsw_point_count.value(),
        )
        publish_manifest(path, legacy)
        var opened = PersistentCollection.open_with_config(
            path, config, maintenance_library_path=""
        )
        assert_true(opened._hnsw_checkpoint_was_hit)
        var pinned = opened.snapshot()
        opened.upsert(0, [200.0, 1.0])
        var collision = String("hnsw-80-", original.generation + 1, "-0.bin")
        write_file_sync(path + "/" + collision, [UInt8(7)])
        opened.flush()
        var migrated = load_manifest(path, 2)
        assert_true(Bool(migrated.hnsw_name))
        assert_equal(migrated.format_version, 5)
        assert_equal(hnsw_base_sequence(migrated), UInt64(80))
        assert_true(migrated.hnsw_name.value() != old_name)
        assert_true(migrated.hnsw_name.value() != collision)
        assert_equal(
            read_file_bytes(path + "/" + migrated.hnsw_name.value()), bytes
        )
        assert_equal(read_file_bytes(path + "/" + collision), [UInt8(7)])
        assert_true(path_exists(path + "/" + old_name))
        pinned.close()
        opened.flush()
        assert_false(path_exists(path + "/" + old_name))
        opened.close()
        var reopened = PersistentCollection.open_with_config(
            path, config, maintenance_library_path=""
        )
        assert_true(reopened._hnsw_checkpoint_was_hit)
        assert_true(reopened._hnsw.base_is_mapped())
        assert_equal(reopened._hnsw.delta_slot_count(), 1)
        assert_equal(reopened.get(0).value().vector[0], Float32(200))
        reopened.close()
        Python.import_module("shutil").rmtree(path)


def test_point_reopen_named_changes_do_not_rebuild_default_graph() raises:
    var path = _path()
    var config = CollectionConfig.defaults(2)
    config.delta_max_points = 1000
    config.rebuild_inactive_percent = 90
    var fields = legacy_vector_fields(config)
    fields.append(VectorFieldSpec(2, "native", 0, 2, 1, 0, 1))
    var collection = PersistentCollection.open_with_fields(
        path, fields^, maintenance_library_path=""
    )
    for id in range(80):
        collection.upsert(id, [Float32(id), 1.0])
    collection.flush()
    var name = load_manifest(path, 2).hnsw_name.value().copy()
    var named: List[PointMutation] = [
        PointMutation(
            0,
            3,
            [
                FieldUpdate.set(
                    2, VectorValue.dense[DType.float16]([Float16(7)])
                )
            ],
        ),
        PointMutation(
            99,
            1,
            [
                FieldUpdate.set(
                    2, VectorValue.dense[DType.float16]([Float16(9)])
                )
            ],
        ),
    ]
    _ = collection.apply_point_batch(named)
    collection.flush()
    assert_equal(load_manifest(path, 2).hnsw_name.value(), name)
    collection.close()
    var reopened = PersistentCollection.open_with_config(
        path, config, maintenance_library_path=""
    )
    assert_true(reopened._hnsw.base_is_mapped())
    assert_equal(reopened._hnsw.delta_slot_count(), 0)
    assert_equal(reopened._hnsw.current_point_count(), 80)
    var changes: List[PointMutation] = [
        PointMutation(1, 3, [FieldUpdate.remove(0)]),
        PointMutation(
            2,
            3,
            [
                FieldUpdate.set(
                    0, VectorValue.dense[DType.float32]([500.0, 1.0])
                )
            ],
        ),
    ]
    _ = reopened.apply_point_batch(changes)
    reopened.flush()
    reopened.compact()
    _ = reopened.backup_to(path + "/backup")
    reopened.close()
    _ = restore_storage(path + "/backup", path + "/restore", 2)
    var restored = PersistentCollection.open_with_config(
        path + "/restore", config, maintenance_library_path=""
    )
    assert_true(restored._hnsw_checkpoint_was_hit)
    assert_true(restored._hnsw.base_is_mapped())
    assert_equal(restored._hnsw.delta_slot_count(), 1)
    assert_equal(restored._hnsw.current_point_count(), 79)
    assert_equal(restored.get_point(99).value().field_count(), 1)
    assert_false(restored.get(1))
    assert_equal(restored.search_l2_approx([500.0, 1.0], 1, 128)[0].id, 2)
    restored.close()
    Python.import_module("shutil").rmtree(path)
