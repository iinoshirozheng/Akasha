from akasha import PersistentCollection, DocumentField, PayloadValue
from akasha.document.jsonb_reader import parse_jsonb
from akasha.storage.filesystem import read_file_bytes, write_file_sync, path_exists
from akasha.storage.manifest import load_manifest, Manifest, publish_manifest, SegmentDescriptor
from test_json_expression_snapshot import _leaf
from std.python import Python
from std.testing import assert_equal, assert_true, TestSuite


def test_v3_catalog_migration_retained_base_and_rebuild() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var collection = PersistentCollection.open(path, 1)
    for id in range(32):
        collection.upsert_document(id, [Float32(id+1)],
            [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1}")))])
    collection.flush()
    collection.close()
    var current = load_manifest(path, 1)
    var old_name = "hnsw-" + String(current.last_sequence) + ".bin"
    var old_bytes = read_file_bytes(path + "/" + current.hnsw_name.value())
    write_file_sync(path + "/" + old_name, old_bytes)
    var segments = List[SegmentDescriptor]()
    for slot in range(len(current.segments)):
        segments.append(current.segments[slot].clone())
    var legacy = Manifest.with_hnsw(1, current.generation, current.last_sequence,
        segments^, old_name, current.hnsw_checksum.value(),
        current.hnsw_config_fingerprint.value(), current.hnsw_point_count.value())
    publish_manifest(path, legacy)
    var reopened = PersistentCollection.open(path, 1)
    assert_true(reopened._hnsw_checkpoint_was_hit)
    assert_equal(load_manifest(path, 1).format_version, 3)
    var pinned = reopened.snapshot()
    reopened.create_json_index("v", "data", "v")
    var migrated = load_manifest(path, 1)
    assert_equal(migrated.format_version, 6)
    assert_equal(migrated.json_catalog.definitions[0].target, UInt8(2))
    assert_true(migrated.hnsw_name.value() != old_name)
    assert_equal(read_file_bytes(path + "/" + migrated.hnsw_name.value()), old_bytes)
    assert_true(path_exists(path + "/" + old_name))
    pinned.close()
    reopened.upsert_document(32, [33.0],
        [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:2}")))])
    reopened.flush()
    var overlay = load_manifest(path, 1)
    assert_equal(overlay.format_version, 6)
    assert_equal(overlay.hnsw_name.value(), migrated.hnsw_name.value())
    reopened.close()
    var retained = PersistentCollection.open(path, 1)
    assert_true(retained._hnsw_checkpoint_was_hit)
    assert_equal(retained.get(32).value().vector[0], Float32(33))
    var snapshot = retained.snapshot()
    assert_equal(snapshot.prepare_json_catalog(_leaf("v", 2), [String("v")]).execute(), [32])
    retained.rebuild_hnsw()
    retained.flush()
    assert_equal(load_manifest(path, 1).format_version, 6)
    assert_equal(load_manifest(path, 1).json_catalog.definitions[0].name, "v")
    retained.close()
    var final = PersistentCollection.open(path, 1)
    assert_true(final._hnsw_checkpoint_was_hit)
    assert_equal(final.json_indexes()[0].name, "v")
    final.close()
    snapshot.close()
    directory.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
