from akasha import PersistentCollection, DocumentField, PayloadValue
from akasha.document.jsonb_reader import parse_jsonb
from test_json_expression_snapshot import _leaf
from akasha.query.control import CancellationToken, QueryControl
from std.python import Python
from std.testing import assert_equal, assert_false, assert_raises, TestSuite


def test_json_scanner_pins_query_and_batches_across_compaction() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    for id in range(5):
        collection.upsert_document(id, [Float32(id), 1.0],
            [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1}")))])
    collection.create_json_index("v", "data", "v")
    var snapshot = collection.snapshot()
    var root = snapshot._acquire()
    var pins = root[]._pins.copy()
    var scanner = snapshot.scanner(2, json_expression=Optional(_leaf("v", 1)), indexes=[String("v")])
    var state = root[].json_indexes[].get("data", "v", 2)
    assert_equal(state[].build_count, 1)
    var again = snapshot.scanner(2, json_expression=Optional(_leaf("v", 1)), indexes=[String("v")])
    assert_equal(state[].build_count, 1)
    again.close()
    snapshot.close()
    _ = root^
    var first = scanner.next_batch()
    assert_equal(first.value().row_count(), 2)
    collection.delete(4)
    collection.drop_json_index("v")
    collection.flush()
    collection.compact()
    collection.close()
    var count = first.value().row_count()
    while True:
        var batch = scanner.next_batch()
        if not batch:
            break
        count += batch.value().row_count()
    assert_equal(count, 5)
    assert_false(Bool(scanner._json_query))
    assert_false(Bool(scanner._root))
    scanner.close()
    assert_equal(first.value().entry(0).id, 0)
    assert_equal(pins[].active_count(), 1)
    _ = first^
    assert_equal(pins[].active_count(), 0)
    directory.cleanup()


def test_json_scanner_expired_deadline_releases_prepared_owner() raises:
    var directory = Python.import_module("tempfile").TemporaryDirectory()
    var collection = PersistentCollection.open(String(py=directory.name), 2)
    collection.upsert_document(1, [1.0, 0.0],
        [DocumentField("data", PayloadValue.jsonb(parse_jsonb("{v:1}")))])
    var snapshot = collection.snapshot()
    var scanner = snapshot.scanner(1, json_expression=Optional(_leaf("v", 1)))
    var token = CancellationToken()
    var expired = QueryControl(token, max_candidates=10, deadline_ns=1)
    with assert_raises(contains="deadline"):
        _ = scanner.next(expired)
    assert_false(Bool(scanner._root))
    assert_false(Bool(scanner._json_query))
    with assert_raises(contains="closed"):
        _ = scanner.next_batch()
    snapshot.close()
    collection.close()
    directory.cleanup()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
