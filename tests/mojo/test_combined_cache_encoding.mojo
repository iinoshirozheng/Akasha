from akasha.document import DocumentField, PayloadValue
from akasha.document.codec import MAX_PAYLOAD_BYTES
from akasha.document.record import clone_fields
from akasha.index.metadata import MetadataIndex
from akasha.index.sparse import SparseElement
from akasha.storage.index_cache import (
    authoritative_index_checksum, metadata_cache_from_authority,
    CACHE_METADATA_KIND, decode_cache_bytes, encode_cache,
)
from akasha.storage.memtable import MemTable
from std.python import Python
from std.testing import assert_equal, assert_raises, TestSuite


def _compare(table: MemTable) raises:
    var expected = MetadataIndex()
    expected.begin_bulk()
    for ordinal in range(table.slot_count()):
        ref entry = table.entry_ref_at(ordinal)
        if entry.tombstone:
            expected.delete(entry.id)
        else:
            expected.upsert(entry.id, clone_fields(entry.fields()))
    expected.finish_bulk()
    var artifact = metadata_cache_from_authority(table, 17, table.last_sequence)
    assert_equal(artifact.kind, CACHE_METADATA_KIND)
    assert_equal(artifact.dimension, table.dimension)
    assert_equal(artifact.generation, UInt64(17))
    assert_equal(artifact.sequence, table.last_sequence)
    assert_equal(artifact.source_checksum, authoritative_index_checksum(table))
    assert_equal(artifact.payload, expected.encode_cache_payload())
    var decoded = decode_cache_bytes(encode_cache(artifact))
    assert_equal(decoded.source_checksum, artifact.source_checksum)
    assert_equal(decoded.payload, artifact.payload)


def test_combined_cache_matches_independent_frozen_bytes() raises:
    var table = MemTable(2)
    _compare(table)
    var empty = metadata_cache_from_authority(table, 0, 0)
    assert_equal(empty.source_checksum, UInt32(0x2707D814))
    var empty_bytes: List[UInt8] = [0, 0, 0, 0]
    assert_equal(empty.payload, empty_bytes)
    var fields: List[DocumentField] = [
        DocumentField("tag", PayloadValue.string("長長長")),
        DocumentField("n", PayloadValue.integer(Int64.MIN)),
        DocumentField("f", PayloadValue.floating(-0.0)),
        DocumentField("b", PayloadValue.boolean(True)),
    ]
    table.apply_document_upsert(-7, 1, [-0.0, 1.5], fields^)
    table.apply_upsert(Int.MIN, 2, [2.0, -3.0])
    table.apply_upsert(42, 3, [4.0, 5.0])
    var artifact = metadata_cache_from_authority(table, 17, 3)
    assert_equal(artifact.source_checksum, UInt32(0xFFE4398B))
    var frozen: List[UInt8] = [3, 0, 0, 0, 249, 255, 255, 255, 255, 255, 255, 255, 1, 0, 0, 0, 52, 0, 0, 0, 4, 0, 0, 0, 3, 0, 116, 97, 103, 1, 9, 0, 0, 0, 233, 149, 183, 233, 149, 183, 233, 149, 183, 1, 0, 110, 2, 0, 0, 0, 0, 0, 0, 0, 128, 1, 0, 102, 3, 0, 0, 0, 0, 0, 0, 0, 128, 1, 0, 98, 4, 1, 0, 0, 0, 0, 0, 0, 0, 128, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0]
    assert_equal(artifact.payload, frozen)
    _compare(table)
    table.apply_delete(-7, 4)
    var deleted = metadata_cache_from_authority(table, 17, 4)
    # Independent little-endian metadata bytes: deleted slot keeps its ID,
    # live=0 and a four-byte empty payload; the other two slots remain live.
    var deleted_bytes: List[UInt8] = [3, 0, 0, 0, 249, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0]
    assert_equal(deleted.payload, deleted_bytes)
    _compare(table)


def test_combined_cache_mutations_tombstones_and_sparse_identity() raises:
    var table = MemTable(2)
    for step in range(96):
        var id = (step * 7) % 19 - 9
        if step % 5 == 0:
            table.apply_delete(id, UInt64(step + 1))
        else:
            var fields: List[DocumentField] = [
                DocumentField("b", PayloadValue.boolean(step % 2 == 0)),
                DocumentField("n", PayloadValue.integer(Int64(step))),
                DocumentField("f", PayloadValue.floating(-0.0 if step % 2 == 0 else 0.0)),
                DocumentField("s", PayloadValue.string(String("台", step))),
            ]
            table.apply_document_upsert(id, UInt64(step + 1), [Float32(step), -0.0], fields^)
        _compare(table)
    table.apply_upsert(100, 97, [1.0, 2.0])
    var before = metadata_cache_from_authority(table, 17, 97)
    table.set_sparse(100, [SparseElement(17, 1.5)])
    var after = metadata_cache_from_authority(table, 17, 97)
    assert_equal(before.source_checksum, after.source_checksum)
    assert_equal(before.payload, after.payload)
    _compare(table)


def test_combined_cache_oversized_payload_error_and_retry() raises:
    var table = MemTable(1)
    var large = String(py=Python.import_module("builtins").str("x").__mul__(MAX_PAYLOAD_BYTES))
    var fields: List[DocumentField] = [DocumentField("large", PayloadValue.string(large))]
    table.apply_document_upsert(1, 1, [1.0], fields^)
    with assert_raises():
        _ = authoritative_index_checksum(table)
    with assert_raises():
        _ = metadata_cache_from_authority(table, 1, 1)
    table.apply_delete(1, 2)
    _compare(table)
    table.apply_upsert(1, 3, [-0.0])
    _compare(table)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
