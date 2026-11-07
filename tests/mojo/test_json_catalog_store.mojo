from akasha.storage.point_store import PointStore
from akasha.storage.manifest import load_manifest
from akasha.index.json_catalog import JsonIndexCatalog, JsonIndexDefinition
from akasha.document.point_state import PointMutation
from test_point_store import _fields, _create
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite


def test_catalog_survives_checkpoint_compaction_reopen_and_drop() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var store = PointStore.open(path, _fields())
    var initial: List[PointMutation] = [_create(1)]
    _ = store.apply_batch(initial)
    var catalog = JsonIndexCatalog()
    catalog.revision = 1
    catalog.definitions.append(JsonIndexDefinition("v", "data", "$.v", 2))
    var generation = store.publish_json_catalog(catalog.copy(), 0)
    assert_equal(load_manifest(path, 2).generation, generation)
    assert_equal(load_manifest(path, 2).format_version, 6)
    var changes: List[PointMutation] = [_create(2)]
    _ = store.apply_batch(changes)
    store.flush()
    assert_equal(load_manifest(path, 2).json_catalog.definitions[0].name, "v")
    with assert_raises():
        _ = store.publish_json_catalog(catalog.copy(), 0)
    store.compact()
    assert_equal(load_manifest(path, 2).json_catalog.revision, UInt64(1))
    store.close()
    var reopened = PointStore.open(path, _fields())
    assert_equal(reopened.last_sequence(), UInt64(2))
    assert_equal(load_manifest(path, 2).json_catalog.definitions[0].target, UInt8(2))
    var dropped = JsonIndexCatalog()
    dropped.revision = 2
    _ = reopened.publish_json_catalog(dropped^, 1)
    reopened.flush()
    reopened.close()
    var final_store = PointStore.open(path, _fields())
    assert_equal(load_manifest(path, 2).format_version, 6)
    assert_equal(load_manifest(path, 2).json_catalog.revision, UInt64(2))
    assert_equal(len(load_manifest(path, 2).json_catalog.definitions), 0)
    final_store.close()
    directory.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
