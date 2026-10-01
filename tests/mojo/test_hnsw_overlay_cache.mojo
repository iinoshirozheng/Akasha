from akasha import (
    CollectionConfig,
    HnswIndex,
    MetricKind,
    PersistentCollection,
    ScalarKind,
)
from akasha.document.vector_schema import legacy_vector_fields
from akasha.storage.checksum import BinaryWriter, crc32_range
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.hnsw_store import encode_hnsw_snapshot
from akasha.storage.index_cache import decode_cache_bytes, publish_cache
from std.python import Python
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def _path() raises -> String:
    return String(
        py=Python.import_module("tempfile").mkdtemp(
            prefix="akasha-overlay-cache-"
        )
    )


def _config() -> CollectionConfig:
    var config = CollectionConfig.defaults(5)
    config.delta_max_points = 1000
    config.rebuild_inactive_percent = 90
    return config^


def _seed(
    path: String, config: CollectionConfig, typed: Bool
) raises -> PersistentCollection:
    var collection = PersistentCollection.open_with_fields(
        path, legacy_vector_fields(config), maintenance_library_path=""
    ) if typed else PersistentCollection.open_with_config(
        path, config, maintenance_library_path=""
    )
    for id in range(64):
        collection.upsert(id, [Float32(id), 1.0, 2.0, 3.0, 4.0])
    collection.flush()
    collection.upsert(0, [101.0, 1.0, 2.0, 3.0, 4.0])
    collection.upsert(0, [102.0, 1.0, 2.0, 3.0, 4.0])
    collection.upsert(5, [105.0, 1.0, 2.0, 3.0, 4.0])
    collection.upsert(71, [71.0, 1.0, 2.0, 3.0, 4.0])
    collection.delete(5)
    collection.delete(1)
    collection.upsert(1, [201.0, 1.0, 2.0, 3.0, 4.0])
    collection.flush()
    return collection^


def _check_authority(collection: PersistentCollection) raises:
    assert_equal(collection._hnsw.current_point_count(), 64)
    assert_true(collection._hnsw.contains_current(0))
    assert_true(collection._hnsw.contains_current(1))
    assert_true(collection._hnsw.contains_current(71))
    assert_false(collection._hnsw.contains_current(5))
    assert_equal(collection._memtable.get(0).value().vector[0], Float32(102))


def test_cached_delta_preserves_topology_and_native_rows_for_both_authorities() raises:
    for typed in [False, True]:
        for scalar in [
            ScalarKind.f32(),
            ScalarKind.f16(),
            ScalarKind.bf16(),
            ScalarKind.i8(),
        ]:
            for metric in [
                MetricKind.l2(),
                MetricKind.dot(),
                MetricKind.cosine(),
            ]:
                if scalar == ScalarKind.i8() and metric == MetricKind.l2():
                    continue
                var path = _path()
                var config = _config()
                config.scalar_kind = scalar.copy()
                config.ann_metric = metric.copy()
                var collection = _seed(path, config, typed)
                assert_true(path_exists(path + "/hnsw-overlay.cache"))
                var before = encode_hnsw_snapshot(
                    collection._hnsw._delta, collection._hnsw_base_sequence
                )
                var expected = collection._hnsw._search_candidates(
                    [100.0, 1.0, 2.0, 3.0, 4.0], 10, 32
                )
                collection.close()
                var reopened = PersistentCollection.open_with_config(
                    path, config, maintenance_library_path=""
                )
                _check_authority(reopened)
                assert_equal(
                    reopened._hnsw._delta.build_distance_evaluations(), 0
                )
                assert_equal(reopened._hnsw._delta.inactive_count(), 2)
                assert_equal(
                    encode_hnsw_snapshot(
                        reopened._hnsw._delta, reopened._hnsw_base_sequence
                    ),
                    before,
                )
                assert_equal(
                    reopened._hnsw._search_candidates(
                        [100.0, 1.0, 2.0, 3.0, 4.0], 10, 32
                    ),
                    expected,
                )
                reopened.close()
                Python.import_module("shutil").rmtree(path)


def test_invalid_overlay_cache_is_rebuilt_from_authority() raises:
    for typed in [False, True]:
        for fault in range(13):
            var path = _path()
            var config = _config()
            var collection = _seed(path, config, typed)
            collection.close()
            var cache_path = path + "/hnsw-overlay.cache"
            var bytes = read_file_bytes(cache_path)
            if fault == 0:
                remove_file_if_exists(cache_path)
            elif fault == 1:
                write_file_sync(cache_path, [UInt8(1), UInt8(2)])
            elif fault == 2:
                bytes[40] ^= UInt8(1)
                write_file_sync(cache_path, bytes)
            elif fault == 3:
                var artifact = decode_cache_bytes(bytes^)
                artifact.generation += 1
                publish_cache(path, "hnsw-overlay.cache", artifact)
            elif fault == 4:
                var artifact = decode_cache_bytes(bytes^)
                artifact.source_checksum ^= UInt32(1)
                publish_cache(path, "hnsw-overlay.cache", artifact)
            elif fault == 5:
                var artifact = decode_cache_bytes(bytes^)
                artifact.payload = [UInt8(1), UInt8(2)]
                publish_cache(path, "hnsw-overlay.cache", artifact)
            elif fault == 10:
                var artifact = decode_cache_bytes(bytes^)
                var wrong_config = config.copy()
                wrong_config.ann_metric = MetricKind.dot()
                var wrong = HnswIndex(wrong_config)
                wrong.add(0, [102.0, 1.0, 2.0, 3.0, 4.0])
                artifact.payload = encode_hnsw_snapshot(wrong, 64)
                publish_cache(path, "hnsw-overlay.cache", artifact)
            elif fault == 11:
                var artifact = decode_cache_bytes(bytes^)
                artifact.sequence += 1
                publish_cache(path, "hnsw-overlay.cache", artifact)
            elif fault == 12:
                var artifact = decode_cache_bytes(bytes^)
                artifact.kind = UInt8(2)
                publish_cache(path, "hnsw-overlay.cache", artifact)
            elif fault == 9:
                # An unsupported outer version with a freshly valid CRC.
                bytes[4] = UInt8(99)
                var writer = BinaryWriter()
                for i in range(len(bytes) - 4):
                    writer.write_u8(bytes[i])
                var body = writer.take_bytes()
                writer.write_bytes(body)
                writer.write_u32(crc32_range(body, 0, len(body)))
                write_file_sync(cache_path, writer.take_bytes())
            else:
                var artifact = decode_cache_bytes(bytes^)
                var wrong = HnswIndex(config)
                wrong.add(
                    99 if fault == 7 else 0,
                    [
                        Float32(999.0 if fault == 8 else 102.0),
                        1.0,
                        2.0,
                        3.0,
                        4.0,
                    ],
                )
                wrong.add(71, [71.0, 1.0, 2.0, 3.0, 4.0])
                wrong.add(1, [201.0, 1.0, 2.0, 3.0, 4.0])
                artifact.payload = encode_hnsw_snapshot(
                    wrong, UInt64(65 if fault == 6 else 64)
                )
                publish_cache(path, "hnsw-overlay.cache", artifact)
            var reopened = PersistentCollection.open_with_config(
                path, config, maintenance_library_path=""
            )
            _check_authority(reopened)
            assert_true(reopened._hnsw.base_is_mapped())
            assert_true(reopened._hnsw._delta.build_distance_evaluations() > 0)
            assert_equal(
                reopened.search_l2_approx([102.0, 1.0, 2.0, 3.0, 4.0], 1, 128)[
                    0
                ].id,
                0,
            )
            reopened.close()
            Python.import_module("shutil").rmtree(path)


def test_new_wal_and_failed_cache_publication_do_not_hide_updates() raises:
    for typed in [False, True]:
        for flush in [False, True]:
            var path = _path()
            var config = _config()
            var collection = _seed(path, config, typed)
            collection.upsert(0, [333.0, 1.0, 2.0, 3.0, 4.0])
            if flush:
                ensure_directory(path + "/hnsw-overlay.cache.tmp")
                collection.flush()
            collection.close()
            var reopened = PersistentCollection.open_with_config(
                path, config, maintenance_library_path=""
            )
            assert_true(reopened._hnsw._delta.build_distance_evaluations() > 0)
            assert_equal(
                reopened.search_l2_approx([333.0, 1.0, 2.0, 3.0, 4.0], 1, 128)[
                    0
                ].id,
                0,
            )
            reopened.close()
            Python.import_module("shutil").rmtree(path)


def test_compaction_preserves_cache_when_authoritative_vectors_do_not_change() raises:
    for typed in [False, True]:
        for earlier_generation in [False, True]:
            var path = _path()
            var config = _config()
            var collection = _seed(path, config, typed)
            var cache = read_file_bytes(path + "/hnsw-overlay.cache")
            var before = encode_hnsw_snapshot(
                collection._hnsw._delta, collection._hnsw_base_sequence
            )
            collection.compact()
            assert_equal(read_file_bytes(path + "/hnsw-overlay.cache"), cache)
            collection.close()
            if earlier_generation:
                # A background compaction may publish after the last cache.
                write_file_sync(path + "/hnsw-overlay.cache", cache)
            var reopened = PersistentCollection.open_with_config(
                path, config, maintenance_library_path=""
            )
            _check_authority(reopened)
            assert_equal(reopened._hnsw._delta.build_distance_evaluations(), 0)
            assert_equal(
                encode_hnsw_snapshot(
                    reopened._hnsw._delta, reopened._hnsw_base_sequence
                ),
                before,
            )
            reopened.close()
            Python.import_module("shutil").rmtree(path)


def test_failed_cache_publication_retries_without_another_mutation() raises:
    for typed in [False, True]:
        var path = _path()
        var config = _config()
        var collection = _seed(path, config, typed)
        var previous = read_file_bytes(path + "/hnsw-overlay.cache")
        collection.upsert(0, [333.0, 1.0, 2.0, 3.0, 4.0])
        ensure_directory(path + "/hnsw-overlay.cache.tmp")
        collection.flush()
        assert_equal(read_file_bytes(path + "/hnsw-overlay.cache"), previous)
        Python.import_module("os").rmdir(path + "/hnsw-overlay.cache.tmp")
        collection.flush()
        assert_true(read_file_bytes(path + "/hnsw-overlay.cache") != previous)
        collection.close()
        var reopened = PersistentCollection.open_with_config(
            path, config, maintenance_library_path=""
        )
        assert_equal(reopened._hnsw._delta.build_distance_evaluations(), 0)
        assert_equal(
            reopened.search_l2_approx([333.0, 1.0, 2.0, 3.0, 4.0], 1, 128)[
                0
            ].id,
            0,
        )
        reopened.close()
        Python.import_module("shutil").rmtree(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
