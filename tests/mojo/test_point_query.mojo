from akasha import CollectionConfig, FieldQuery, PersistentCollection
from akasha.document.point_state import FieldUpdate, PointMutation
from akasha.document.vector_schema import VectorFieldSpec, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite


def _fields() raises -> List[VectorFieldSpec]:
    var fields = legacy_vector_fields(CollectionConfig.defaults(1))
    fields.append(VectorFieldSpec(2, "v", 0, 0, 0, 0, 1))
    return fields^


def _put(mut collection: PersistentCollection, id: Int, value: Float32) raises:
    var updates: List[FieldUpdate] = [
        FieldUpdate.set(2, VectorValue.dense[DType.float32]([value]))
    ]
    var batch: List[PointMutation] = [PointMutation(id, 1, updates^)]
    _ = collection.apply_point_batch(batch)


def test_point_query_uses_one_snapshot_and_excludes_before_topk() raises:
    var path = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-point-query-"))
    var collection = PersistentCollection.open_with_fields(path, _fields(), maintenance_library_path="")
    _put(collection, 1, 1)
    _put(collection, 2, 2)
    _put(collection, 3, 3)
    var captured = Optional(collection.snapshot())
    var initial = captured.value().search_field_by_id("v", 3, 2)
    assert_equal(initial[0].id, 2)
    assert_equal(initial[1].id, 1)
    _put(collection, 3, -1)
    var current = collection.search_field_by_id("v", 3, 2)
    assert_equal(current[0].id, 1)
    assert_equal(current[0].score, Float64(-1))
    collection.close()
    var retained = captured.value().search_field_by_id("v", 3, 2)
    assert_equal(retained[0].id, 2)
    assert_equal(retained[0].score, Float64(6))
    with assert_raises():
        _ = captured.value().search_field_by_id("v", 99, 2)

    # Registry identity changes across reopen. Directory aliases must still
    # identify one collection and exclude the source ID before selection.
    var alias_path = path + "-alias"
    Python.import_module("os").symlink(path, alias_path)
    var reopened = PersistentCollection.open_with_fields(alias_path, _fields(), maintenance_library_path="")
    # Without canonical same-collection exclusion, this new value would win
    # when queried with the old snapshot's value (100 * 3).
    _put(reopened, 3, 100)
    var looked_up = reopened.search_field_by_id("v", 3, 2, lookup=captured)
    assert_equal(looked_up[0].id, 2)
    assert_equal(looked_up[0].score, Float64(6))
    captured.value().close()
    with assert_raises():
        _ = reopened.search_field_by_id("v", 3, 2, lookup=captured)
    reopened.close()
    Python.import_module("os").unlink(alias_path)
    Python.import_module("shutil").rmtree(path)


def test_external_lookup_keeps_same_numbered_id_and_source_lifetime() raises:
    var base = String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-point-external-"))
    var target = PersistentCollection.open_with_fields(base + "/target", _fields(), maintenance_library_path="")
    var source = PersistentCollection.open_with_fields(base + "/source", _fields(), maintenance_library_path="")
    _put(target, 1, 2)
    _put(target, 2, 1)
    _put(source, 1, 5)
    var lookup = Optional(source.snapshot())
    source.close()
    var hits = target.search_field_by_id("v", 1, 1, lookup=lookup)
    assert_equal(hits[0].id, 1)
    assert_equal(hits[0].score, Float64(10))
    target.close()
    lookup.value().close()
    Python.import_module("shutil").rmtree(base)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
