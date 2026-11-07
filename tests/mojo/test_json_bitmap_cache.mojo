from akasha import PersistentCollection, DocumentField, PayloadValue
from akasha.document.jsonb_reader import parse_jsonb
from akasha.storage.json_bitmap_cache import json_bitmap_cache_name
from akasha.storage.filesystem import path_exists, read_file_bytes, write_file_sync
from test_json_expression_snapshot import _leaf
from std.python import Python
from std.testing import assert_equal, assert_true, TestSuite


def test_json_disk_cache_reopen_hit_corruption_and_source_miss() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert_document(-7, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1}")))])
    collection.create_json_index("v", "data", "v")
    var file = path + "/" + json_bitmap_cache_name("data", "v", 2)
    assert_true(path_exists(file))
    var original = read_file_bytes(file)
    collection.close()
    var reopened = PersistentCollection.open(path, 2)
    var snapshot = reopened.snapshot()
    var root = snapshot._acquire()
    var state = root[].json_indexes[].get("data", "v", 2)
    # A hit bypasses training, including its injected failure.
    state[].fail_for_test = True
    var prepared = snapshot.prepare_json_catalog(_leaf("v", 1), [String("v")])
    assert_equal(prepared.execute(), [-7])
    assert_equal(state[].failure_count, 0)
    reopened.upsert_document(-7, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:2}")))])
    var newer = reopened.snapshot()
    assert_equal(newer.prepare_json_catalog(_leaf("v", 2), [String("v")]).execute(), [-7])
    assert_equal(newer.prepare_json_catalog(_leaf("v", 1), [String("v")]).execute(), List[Int]())
    assert_equal(prepared.execute(), [-7])
    reopened.rebuild_json_index("v")
    reopened.close()
    var bytes = read_file_bytes(file)
    assert_true(bytes != original)
    bytes[len(bytes)-1] ^= 1
    write_file_sync(file, bytes)
    var corrupted = PersistentCollection.open(path, 2)
    var recovered = corrupted.snapshot()
    assert_equal(recovered.prepare_json_catalog(_leaf("v", 2), [String("v")]).execute(), [-7])
    corrupted.rebuild_json_index("v")
    corrupted.close()
    var restored = PersistentCollection.open(path, 2)
    var fresh = restored.snapshot()
    var fresh_root = fresh._acquire()
    var fresh_state = fresh_root[].json_indexes[].get("data", "v", 2)
    fresh_state[].fail_for_test = True
    assert_equal(fresh.prepare_json_catalog(_leaf("v", 2), [String("v")]).execute(), [-7])
    restored.close()
    directory.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
