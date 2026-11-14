from akasha import PersistentCollection, DocumentField, PayloadValue
from akasha.document.jsonb_reader import parse_jsonb
from test_json_expression_snapshot import _leaf
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite
from max.algorithm import parallelize
from akasha.storage.json_scalar_cache import json_btree_cache_name
from akasha.storage.filesystem import remove_file_if_exists


def test_catalog_create_capture_query_reopen_and_drop() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var path = String(py=directory.name)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert_document(-1, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1}")))])
    var before = collection.snapshot()
    collection.create_json_index("by_v", "data", "v", kind=2)
    assert_equal(collection.json_indexes()[0].target, UInt8(2))
    assert_equal(collection.json_indexes()[0].kind, UInt8(2))
    assert_equal(len(before.json_indexes()), 0)
    with assert_raises():
        _ = before.prepare_json_catalog(_leaf("v", 1), [String("by_v")])
    var captured = collection.snapshot()
    var query = captured.prepare_json_catalog(_leaf("v", 1), [String("by_v")])
    assert_equal(query.indexed_leaf_count(), 1)
    assert_equal(query.execute(), [-1])
    var root = captured._acquire()
    var artifact = root[].json_indexes[].get("data", "v", 2, 2)
    assert_equal(artifact[].build_count, 1)
    _ = captured.prepare_json_catalog(_leaf("v", 2), [String("by_v")])
    assert_equal(artifact[].build_count, 1)
    captured.rebuild_json_index("by_v")
    assert_equal(artifact[].build_count, 2)
    artifact[].fail_for_test = True
    with assert_raises():
        captured.rebuild_json_index("by_v")
    assert_equal(artifact[].build_count, 2)
    assert_equal(artifact[].failure_count, 1)
    assert_equal(captured.prepare_json_catalog(_leaf("v", 1), [String("by_v")]).execute(), [-1])
    artifact[].fail_for_test = False
    with assert_raises():
        collection.create_json_index("by_v", "data", "v", kind=2)
    collection.upsert_document(2, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:2}")))])
    collection.flush()
    collection.compact()
    collection.close()
    var reopened = PersistentCollection.open(path, 2)
    assert_equal(reopened.json_indexes()[0].name, "by_v")
    var latest = reopened.snapshot()
    var new_root = latest._acquire()
    var new_artifact = new_root[].json_indexes[].get("data", "v", 2, 2)
    assert_equal(new_artifact[].build_count, 0)
    assert_equal(latest.prepare_json_catalog(_leaf("v", 2), [String("by_v")]).execute(), [2])
    assert_equal(new_artifact[].build_count, 1)
    reopened.drop_json_index("by_v")
    assert_equal(len(reopened.json_indexes()), 0)
    assert_equal(captured.json_indexes()[0].name, "by_v")
    assert_equal(captured.prepare_json_catalog(_leaf("v", 1), [String("by_v")]).execute(), [-1])
    assert_equal(query.execute(), [-1])
    reopened.close()
    var dropped = PersistentCollection.open(path, 2)
    assert_equal(len(dropped.json_indexes()), 0)
    dropped.close()
    directory.cleanup()


def test_catalog_learned_type_does_not_change_after_writes() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    collection.upsert_document(1, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1}")))])
    collection.create_json_index("by_v", "data", "v", kind=2)
    collection.upsert_document(1, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:'different'}")))])
    var snapshot = collection.snapshot()
    assert_equal(snapshot.json_indexes()[0].target, UInt8(2))
    with assert_raises():
        collection.rebuild_json_index("by_v")
    with assert_raises():
        _ = snapshot.prepare_json_catalog(_leaf("v", 1), [String("by_v")])
    collection.drop_json_index("by_v")
    collection.create_json_index("by_v", "data", "v", kind=2)
    assert_equal(collection.json_indexes()[0].target, UInt8(4))
    collection.close()
    directory.cleanup()


def test_parallel_preparation_shares_one_complete_artifact() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    collection.upsert_document(1, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1}")))])
    collection.create_json_index("v", "data", "v", kind=2)
    remove_file_if_exists(String(py=directory.name) + "/" + json_btree_cache_name("data", "v", 2))
    var captured = collection.snapshot()
    var root = captured._acquire()
    var state = root[].json_indexes[].get("data", "v", 2, 2)
    state[].fail_for_test = True
    with assert_raises():
        _ = captured.prepare_json_catalog(_leaf("v", 1), [String("v")])
    state[].fail_for_test = False
    state[].delay_for_test = 0.05
    var failures = List[Int](length=8, fill=0)

    def run_query(index: Int) {imm captured, mut failures}:
        try:
            var prepared = captured.prepare_json_catalog(_leaf("v", 1), [String("v")])
            assert_equal(prepared.execute(), [1])
        except:
            failures[index] += 1

    parallelize(run_query, 8, 8)
    for failure in failures:
        assert_equal(failure, 0)
    assert_equal(state[].build_count, 1)
    assert_equal(state[].failure_count, 1)
    collection.close()
    captured.close()
    directory.cleanup()


def test_kind_registry_isolation_and_unhandled_index_keeps_prior_mask() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    collection.upsert_document(1, [1.0, 0.0], [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1}")))])
    collection.create_json_index("tree", "data", "v", kind=2)
    collection.create_json_index("bitmap", "data", "v")
    collection.create_json_index("path_only", "data", "$.v")
    var snapshot = collection.snapshot()
    var prepared = snapshot.prepare_json_catalog(_leaf("v", 1), [String("tree"), String("path_only")])
    assert_equal(prepared.indexed_leaf_count(), 1)
    assert_equal(prepared.execute(), [1])
    _ = snapshot.prepare_json_catalog(_leaf("v", 1), [String("bitmap")])
    var root = snapshot._acquire()
    var bitmap = root[].json_indexes[].get("data", "v", 2, 1)
    var btree = root[].json_indexes[].get("data", "v", 2, 2)
    assert_equal(bitmap[].ready.value()[].kind(), UInt8(1))
    assert_equal(btree[].ready.value()[].kind(), UInt8(2))
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
