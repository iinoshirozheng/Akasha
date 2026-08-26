from akasha import (
    DocumentField,
    FieldProjection,
    PayloadValue,
    PersistentCollection,
)
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_false, assert_true, TestSuite


def _reset(path: String) raises:
    ensure_directory(path)
    remove_file_if_exists(path + "/manifest.bin")
    remove_file_if_exists(path + "/wal.bin")
    remove_file_if_exists(path + "/sparse.wal")


def _fields() raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(DocumentField("chunk", PayloadValue.string("hello")))
    fields.append(DocumentField("rank", PayloadValue.integer(7)))
    fields.append(DocumentField("visible", PayloadValue.boolean(True)))
    return fields^


def test_projection_omits_vector_and_selects_named_fields() raises:
    var path = String("/tmp/akasha-phase14-projection")
    _reset(path)
    var collection = PersistentCollection.open(path, 3)
    var fields = _fields()
    collection.upsert_document(9, [1.0, 2.0, 3.0], fields^)

    var names = List[String]()
    names.append("rank")
    names.append("chunk")
    var projection = FieldProjection.named(False, names^)
    var projected = collection.get_projected(9, projection)
    assert_true(Bool(projected))
    assert_equal(len(projected.value().vector), 0)
    assert_equal(len(projected.value().fields), 2)
    assert_equal(projected.value().fields[0].name, "chunk")
    assert_equal(projected.value().fields[1].name, "rank")
    assert_false(Bool(projected.value().get_field("visible")))
    collection.close()


def test_projection_is_snapshot_stable_and_validates_names() raises:
    var path = String("/tmp/akasha-phase14-projection-snapshot")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var fields = _fields()
    collection.upsert_document(1, [4.0, 5.0], fields^)
    var snapshot = collection.snapshot()

    var replacement = List[DocumentField]()
    replacement.append(
        DocumentField("chunk", PayloadValue.string("replacement"))
    )
    collection.upsert_document(1, [8.0, 9.0], replacement^)

    var projection = FieldProjection.all(True)
    var old = snapshot.get_projected(1, projection)
    assert_equal(old.value().vector[0], Float32(4.0))
    assert_equal(
        old.value().get_field("chunk").value().as_string(), "hello"
    )

    var invalid = List[String]()
    invalid.append("")
    try:
        _ = FieldProjection.named(True, invalid^)
        assert_true(False, msg="empty projection name must fail")
    except:
        pass
    snapshot.close()
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
