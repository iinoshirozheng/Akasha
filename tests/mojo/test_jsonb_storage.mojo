from akasha import PersistentCollection, CollectionConfig
from akasha.document import JsonbValue, PayloadValue, DocumentField
from akasha.document.point_state import PointMutation, FieldUpdate, PointState, PointField
from akasha.document.vector_schema import legacy_vector_fields, VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.storage.point_store import PointStore
from akasha.storage.point_wal import encode_point_batch, decode_point_batch
from akasha.storage.point_segment import encode_point_segment, read_point_segment, decode_point_segment
from akasha.storage.field_catalog import load_field_catalog
from akasha.storage.filesystem import read_file_bytes, write_file_sync, remove_file_if_exists
from akasha.storage.operations import restore_storage
from akasha.storage.manifest import load_manifest
from test_jsonb_payload import _golden_value
from test_field_envelopes import _crc
from std.python import Python
from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite


def _temp() raises -> String:
    return String(py=Python.import_module("tempfile").mkdtemp(prefix="akasha-jsonb-storage-"))


def _remove(path: String) raises:
    _ = Python.import_module("shutil").rmtree(path)


def _fields() raises -> List[VectorFieldSpec]:
    return legacy_vector_fields(CollectionConfig.defaults(2))


def _payload() raises -> List[DocumentField]:
    return [DocumentField("x", _golden_value()),
        DocumentField("root", PayloadValue.jsonb(JsonbValue.timestamp_tz(-1, 28800)))]


def _mutation(id: Int) raises -> PointMutation:
    return PointMutation(id, 1, [FieldUpdate.set(0, VectorValue.dense[DType.float32]([1, 2]))], Optional(_payload()))


def _read_u32(bytes: List[UInt8], offset: Int) -> Int:
    var result = UInt32(0)
    for i in range(4):
        result |= UInt32(bytes[offset + i]) << UInt32(i * 8)
    return Int(result)


def test_mixed_payload_versions_recover_and_checkpoint_to_v3() raises:
    var path = _temp()
    var store = PointStore.open(path, _fields())
    store.close()
    var catalog = load_field_catalog(path)
    var wal = List[UInt8]()
    for version in [1, 2, 3]:
        var fields: List[DocumentField]
        if version == 1:
            fields = [DocumentField("x", PayloadValue.integer(3))]
        elif version == 2:
            fields = [DocumentField("x", PayloadValue.array([PayloadValue.null(), PayloadValue.unsigned(UInt64.MAX)]))]
        else:
            fields = _payload()
        var mutations: List[PointMutation] = [PointMutation(version, 1, [], Optional(fields^))]
        wal.extend(encode_point_batch(UInt64(version), mutations, catalog, payload_version=version))
    write_file_sync(path + "/wal.bin", wal)
    var reopened = PointStore.open(path, _fields())
    assert_equal(reopened.last_sequence(), UInt64(3))
    assert_equal(reopened.get(1).value().payload()[0].value.as_int(), Int64(3))
    assert_equal(reopened.get(2).value().payload()[0].value.get_index(1).value().as_uint(), UInt64.MAX)
    assert_true(reopened.get(3).value().payload()[0].value.same_representation(_golden_value()))
    var identity = read_file_bytes(path + "/collection.bin")
    reopened.flush()
    assert_equal(reopened.last_sequence(), UInt64(3))
    assert_equal(read_file_bytes(path + "/collection.bin"), identity)
    var manifest = load_manifest(path, 2)
    var segment = read_file_bytes(path + "/" + manifest.segments[0].name)
    var offset = 48
    for _ in range(3):
        assert_equal(segment[offset + 40], UInt8(255))
        assert_equal(segment[offset + 44], UInt8(3))
        offset += _read_u32(segment, offset)
    assert_equal(offset, len(segment) - 4)
    reopened.close()
    var checkpointed = PointStore.open(path, _fields())
    assert_equal(checkpointed.get(1).value().sequence, UInt64(1))
    assert_equal(checkpointed.get(2).value().sequence, UInt64(2))
    assert_true(checkpointed.get(3).value().payload()[0].value.same_representation(_golden_value()))
    checkpointed.close()
    _remove(path)


def test_jsonb_snapshot_checkpoint_compaction_backup_and_owned_reads() raises:
    var path = _temp()
    var backup = path + "-backup"
    var restore = path + "-restore"
    var collection = PersistentCollection.open(path, 2)
    var mutations: List[PointMutation] = [_mutation(1)]
    _ = collection.apply_point_batch(mutations)
    collection.close()
    collection = PersistentCollection.open(path, 2)
    assert_true(collection.get_point(1).value().payload()[0].value.same_representation(_golden_value()))
    collection.flush()
    var snapshot = collection.snapshot()
    var owned = collection.get_point(1)
    collection.upsert_document(1, [3, 4], [DocumentField("changed", PayloadValue.null())])
    collection.flush()
    collection.compact()
    assert_true(snapshot.get(1).value().fields[0].value.same_representation(_golden_value()))
    _ = collection.apply_point_batch(mutations)
    _ = collection.backup_to(backup)
    snapshot.close()
    collection.close()
    assert_true(owned.value().payload()[0].value.same_representation(_golden_value()))
    assert_equal(owned.value().payload()[1].value.as_jsonb().as_timestamp(), Int64(-1))
    _ = restore_storage(backup, restore, 2)
    var restored = PersistentCollection.open(restore, 2)
    assert_true(restored.get_point(1).value().payload()[0].value.same_representation(_golden_value()))
    assert_equal(restored.get_point(1).value().payload()[1].value.as_jsonb().timezone_offset(), Int32(28800))
    restored.close()
    _remove(path)
    _remove(backup)
    _remove(restore)


def test_jsonb_mapped_segments_own_bytes_and_reject_crc_valid_bad_bodies() raises:
    var path = _temp()
    var store = PointStore.open(path, _fields())
    store.close()
    var catalog = load_field_catalog(path)
    var payload: List[DocumentField] = [DocumentField("x", PayloadValue.jsonb(JsonbValue.string("ok")))]
    var points: List[PointState] = [PointState.live(1, 1, 0, [], payload^)]
    var bytes = encode_point_segment(1, 0, 1, points, catalog)
    var segment_path = path + "/standalone.bin"
    write_file_sync(segment_path, bytes)
    var loaded = read_point_segment(segment_path, catalog)
    remove_file_if_exists(segment_path)
    assert_equal(loaded.points[0].payload()[0].value.as_jsonb().as_string(), "ok")
    for offset in [92, 103, 104, 108, 112]:
        # Inner version, value tag/length, JSONB header and jentry.
        var corrupt = bytes.copy()
        corrupt[offset] = 255
        _crc(corrupt)
        write_file_sync(segment_path, corrupt)
        with assert_raises():
            _ = decode_point_segment(corrupt, catalog)
        with assert_raises():
            _ = read_point_segment(segment_path, catalog)
        assert_equal(read_file_bytes(segment_path), corrupt)
    _remove(path)


def test_invalid_jsonb_batch_does_not_publish_a_prefix() raises:
    var path = _temp()
    var collection = PersistentCollection.open(path, 2)
    var baseline: List[PointMutation] = [_mutation(9)]
    _ = collection.apply_point_batch(baseline)
    var before = read_file_bytes(path + "/wal.bin")
    var bytes = List[UInt8](length=4 + 4 * (JsonbValue.MAX_NODES - 1), fill=0)
    bytes[0] = 0x80
    bytes[2] = 0xff
    bytes[3] = 0xff
    var oversized: List[DocumentField] = [DocumentField("x", PayloadValue.jsonb(JsonbValue(Span(bytes)))), DocumentField("extra", PayloadValue.null())]
    var mutations: List[PointMutation] = [_mutation(1), PointMutation(2, 1, [], Optional(oversized^))]
    with assert_raises(contains="node count"):
        _ = collection.apply_point_batch(mutations)
    assert_false(Bool(collection.get_point(1)))
    assert_false(Bool(collection.get_point(2)))
    assert_equal(collection.last_sequence(), UInt64(1))
    assert_equal(read_file_bytes(path + "/wal.bin"), before)
    collection.close()
    var reopened = PersistentCollection.open(path, 2)
    assert_equal(reopened.last_sequence(), UInt64(1))
    assert_true(reopened.get_point(9).value().payload()[0].value.same_representation(_golden_value()))
    reopened.close()
    _remove(path)


def test_corrupt_complete_jsonb_wal_fails_without_repair() raises:
    for mode in range(3):
        var path = _temp()
        var store = PointStore.open(path, _fields())
        var baseline: List[PointMutation] = [_mutation(9)]
        _ = store.apply_batch(baseline)
        store.flush()
        store.close()
        var catalog = load_field_catalog(path)
        var payload: List[DocumentField] = [DocumentField("x", PayloadValue.jsonb(JsonbValue.string("ok")))]
        var mutations: List[PointMutation] = [PointMutation(1, 1, [], Optional(payload^)), _mutation(2)]
        var bad = encode_point_batch(2, mutations, catalog)
        if mode == 0:
            bad[len(bad) - 1] ^= 1
        else:
            bad[68 if mode == 1 else 84] = 0  # unsupported payload version or JSONB header
            _crc(bad)
        with assert_raises():
            _ = decode_point_batch(bad, catalog)
        write_file_sync(path + "/wal.bin", bad)
        var manifest = read_file_bytes(path + "/manifest.bin")
        with assert_raises():
            _ = PointStore.open(path, _fields())
        assert_equal(read_file_bytes(path + "/wal.bin"), bad)
        assert_equal(read_file_bytes(path + "/manifest.bin"), manifest)
        _remove(path)


def test_torn_jsonb_wal_batch_discards_all_members_and_allows_new_writes() raises:
    for partial in [True, False]:
        var path = _temp()
        var store = PointStore.open(path, _fields())
        var baseline: List[PointMutation] = [_mutation(9)]
        _ = store.apply_batch(baseline)
        var mutations: List[PointMutation] = [_mutation(1), _mutation(2)]
        var prefix = read_file_bytes(path + "/wal.bin")
        _ = store.apply_batch(mutations)
        store.close()
        var complete = read_file_bytes(path + "/wal.bin")
        var end = len(prefix) + (len(complete) - len(prefix)) // 2 if partial else len(complete) - 1
        var torn = List[UInt8]()
        torn.extend(Span(complete)[:end])
        write_file_sync(path + "/wal.bin", torn)
        var reopened = PointStore.open(path, _fields())
        assert_equal(reopened.last_sequence(), UInt64(1))
        assert_false(Bool(reopened.get(1)))
        assert_false(Bool(reopened.get(2)))
        assert_true(reopened.get(9).value().payload()[0].value.same_representation(_golden_value()))
        assert_equal(read_file_bytes(path + "/wal.bin"), prefix)
        _ = reopened.apply_batch(mutations)
        reopened.close()
        var again = PointStore.open(path, _fields())
        assert_equal(again.last_sequence(), UInt64(3))
        assert_true(again.get(2).value().payload()[0].value.same_representation(_golden_value()))
        again.close()
        _remove(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
