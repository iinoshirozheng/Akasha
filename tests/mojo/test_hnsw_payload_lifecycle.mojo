from akasha import CollectionConfig, MetricKind, PersistentCollection
from akasha.document.record import DocumentField
from akasha.document.value import PayloadValue
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.query.filter_ast import FilterCondition, FilterExpression
from std.ffi import c_int, external_call
from std.testing import assert_equal, assert_true, TestSuite


def _config() -> CollectionConfig:
    var config = CollectionConfig.defaults(1)
    config.ann_metric = MetricKind.l2()
    config.m = 2
    config.m0 = 2
    config.ef_construction = 32
    config.default_ef_search = 16
    config.max_ef_search = 128
    config.delta_max_points = 1000
    return config^


def _path(suffix: String) -> String:
    return String("/tmp/akasha-payload-lifecycle-", Int(external_call["getpid", c_int]()), "-", suffix)


def _payload(group: Int) raises -> List[DocumentField]:
    return [DocumentField("group", PayloadValue.integer(Int64(group)))]


def _assert_query(mut collection: PersistentCollection, query: Float32, expected: Int) raises:
    var expression = FilterExpression.condition(FilterCondition.equal("group", PayloadValue.integer(0)))
    var exact = collection.search_l2_where([query], 3, expression)
    var approximate = collection.search_l2_approx_where([query], 3, 32, expression)
    assert_equal(len(approximate), 3)
    assert_equal(approximate[0].id, expected)
    for i in range(3):
        assert_equal(approximate[i].id, exact[i].id)
        assert_equal(approximate[i].score, exact[i].score)


def test_first_payload_flush_rebuilds_and_reopen_preserves_filtered_graph() raises:
    var path = _path("legacy")
    var config = _config()
    var collection = PersistentCollection.open_with_config(path, config.copy())
    for id in range(48):
        collection.upsert_document(id, [Float32(id)], _payload(id % 3))
    _assert_query(collection, 42, 42)
    collection.flush()
    assert_true(collection.hnsw_available())
    assert_equal(collection._hnsw.delta_slot_count(), 0)
    assert_true(collection._hnsw.checkpoint_base().maximum_neighbor_count(0) > config.m0)
    _assert_query(collection, 42, 42)
    collection.close()
    var reopened = PersistentCollection.open_with_config(path, config.copy())
    assert_true(reopened._hnsw_checkpoint_was_hit)
    _assert_query(reopened, 42, 42)
    reopened.upsert_document(47, [47.0], _payload(0))
    reopened.delete(45)
    _assert_query(reopened, 47, 47)
    reopened.flush()
    reopened.close()
    var recovered = PersistentCollection.open_with_config(path, config)
    _assert_query(recovered, 47, 47)
    recovered.compact()
    _assert_query(recovered, 47, 47)
    recovered.close()


def test_payload_only_point_update_moves_default_vector_into_overlay() raises:
    var path = _path("points")
    var config = _config()
    var collection = PersistentCollection.open_with_fields(path, legacy_vector_fields(config))
    var batch = List[PointMutation]()
    for id in range(48):
        batch.append(PointMutation(id, 1, [FieldUpdate.set(0, VectorValue.dense[DType.float32]([Float32(id)]))], Optional(_payload(id % 3))))
    _ = collection.apply_point_batch(batch)
    collection.flush()
    assert_equal(collection._hnsw.delta_slot_count(), 0)
    var dense_before = collection._memtable.entry_ref_at(collection._memtable.ordinal_for(47)).dense_address()
    var edits: List[PointMutation] = [PointMutation(47, 3, [], Optional(_payload(0)))]
    _ = collection.apply_point_batch(edits)
    assert_equal(collection._memtable.entry_ref_at(collection._memtable.ordinal_for(47)).dense_address(), dense_before)
    assert_equal(collection._hnsw.delta_slot_count(), 1)
    _assert_query(collection, 47, 47)
    collection.flush()
    collection.close()
    var reopened = PersistentCollection.open_with_fields(path, legacy_vector_fields(config))
    _assert_query(reopened, 47, 47)
    reopened.rebuild_hnsw()
    assert_equal(reopened._hnsw.delta_slot_count(), 0)
    _assert_query(reopened, 47, 47)
    reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
