from akasha import (
    DocumentField,
    PayloadValue,
    PersistentCollection,
)
from akasha.storage.checksum import BinaryWriter, crc32_range
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import load_manifest
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(directory: String) raises:
    ensure_directory(directory)
    remove_file_if_exists(directory + "/wal.bin")
    remove_file_if_exists(directory + "/manifest.bin")
    remove_file_if_exists(directory + "/manifest.bin.tmp")
    for sequence in range(8):
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-" + String(sequence) + ".bin.tmp"
        )
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin"
        )
        remove_file_if_exists(
            directory + "/segment-base-" + String(sequence) + ".bin.tmp"
        )


def _document_fields() raises -> List[DocumentField]:
    var fields = List[DocumentField]()
    fields.append(
        DocumentField("chunk", PayloadValue.string("vector databases"))
    )
    fields.append(
        DocumentField("image_uri", PayloadValue.string("images/1.png"))
    )
    fields.append(DocumentField("page", PayloadValue.integer(7)))
    fields.append(DocumentField("score", PayloadValue.floating(0.9)))
    fields.append(DocumentField("verified", PayloadValue.boolean(True)))
    return fields^


def _encode_v1_wal() -> List[UInt8]:
    var writer = BinaryWriter()
    writer.write_u8(0x41)
    writer.write_u8(0x4B)
    writer.write_u8(0x57)
    writer.write_u8(0x4C)
    writer.write_u16(1)
    writer.write_u8(1)
    writer.write_u8(0)
    writer.write_u32(40)
    writer.write_u64(1)
    writer.write_i64(99)
    writer.write_u32(1)
    writer.write_f32(3.0)
    var body = writer.take_bytes()
    var checksum = crc32_range(body, 4, len(body))
    var complete = BinaryWriter()
    complete.write_bytes(body)
    complete.write_u32(checksum)
    return complete.take_bytes()


def test_upsert_document_is_immediately_available_through_get() raises:
    var path = String("/tmp/akasha-phase4-document-live")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var fields = _document_fields()

    collection.upsert_document(10, [1.0, 0.0], fields^)
    var record = collection.get(10)

    assert_true(Bool(record))
    assert_equal(record.value().id, 10)
    assert_equal(
        record.value().get_field("chunk").value().as_string(),
        "vector databases",
    )
    assert_equal(record.value().get_field("page").value().as_int(), Int64(7))


def test_document_survives_wal_only_reopen() raises:
    var path = String("/tmp/akasha-phase4-document-wal")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var fields = _document_fields()
    collection.upsert_document(1, [2.0], fields^)
    collection.close()

    var reopened = PersistentCollection.open(path, 1)
    var record = reopened.get(1)

    assert_true(Bool(record))
    assert_equal(
        record.value().get_field("image_uri").value().as_string(),
        "images/1.png",
    )


def test_document_survives_flush_and_search_result_lookup() raises:
    var path = String("/tmp/akasha-phase4-document-flush")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    var fields = _document_fields()
    collection.upsert_document(20, [2.0, 0.0], fields^)
    collection.upsert(30, [0.0, 1.0])
    collection.flush()
    collection.close()

    var reopened = PersistentCollection.open(path, 2)
    var query: List[Float32] = [1.0, 0.0]
    var results = reopened.search_dot(query, 1)
    var record = reopened.get(results[0].id)

    assert_equal(results[0].id, 20)
    assert_equal(record.value().get_field("verified").value().as_bool(), True)


def test_vector_upsert_clears_payload_and_delete_hides_document() raises:
    var path = String("/tmp/akasha-phase4-document-replace")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var fields = _document_fields()
    collection.upsert_document(5, [1.0], fields^)

    collection.upsert(5, [2.0])
    var vector_only = collection.get(5)
    assert_equal(len(vector_only.value().fields), 0)

    collection.delete(5)
    assert_false(Bool(collection.get(5)))


def test_invalid_document_does_not_consume_sequence() raises:
    var path = String("/tmp/akasha-phase4-document-invalid")
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    var duplicate = List[DocumentField]()
    duplicate.append(DocumentField("source", PayloadValue.string("a")))
    duplicate.append(DocumentField("source", PayloadValue.string("b")))

    with assert_raises():
        collection.upsert_document(1, [1.0], duplicate^)
    assert_equal(collection.last_sequence(), UInt64(0))

    var valid = _document_fields()
    collection.upsert_document(1, [1.0], valid^)
    assert_equal(collection.last_sequence(), UInt64(1))


def test_v1_database_opens_and_flushes_as_v3_base_segment() raises:
    var path = String("/tmp/akasha-phase4-document-upgrade")
    _reset(path)
    var v1_wal = _encode_v1_wal()
    write_file_sync(path + "/wal.bin", v1_wal)

    var collection = PersistentCollection.open(path, 1)
    var old_record = collection.get(99)
    assert_true(Bool(old_record))
    assert_equal(len(old_record.value().fields), 0)
    collection.flush()
    collection.close()

    var manifest = load_manifest(path, 1)
    assert_equal(manifest.format_version, 2)
    assert_equal(manifest.segments[0].level, 1)
    var segment = read_file_bytes(path + "/segment-base-1.bin")
    assert_equal(segment[4], UInt8(3))
    var reopened = PersistentCollection.open(path, 1)
    assert_true(Bool(reopened.get(99)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
