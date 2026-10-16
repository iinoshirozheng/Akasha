from akasha.common.config import CollectionConfig
from akasha.document.point_codec import encode_point_record
from akasha.document.point_state import PointField, PointState
from akasha.document.vector_schema import FieldCatalog, legacy_vector_fields
from akasha.document.vector_value import VectorValue
from akasha.storage.checksum import BinaryWriter, CRC32_INITIAL, crc32_update
from akasha.storage.committed_compaction import (
    capture_compaction_inputs,
    build_compaction_output,
    discard_compaction_output,
)
from akasha.storage.field_catalog import (
    load_field_catalog,
    field_catalog_checksum,
)
from akasha.storage.filesystem import sync_file
from akasha.storage.manifest import (
    Manifest,
    SegmentDescriptor,
    publish_manifest,
)
from akasha.storage.mapped_file import MappedFile
from akasha.storage.point_store import PointStore
from std.ffi import c_int, external_call
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, TestSuite


def _peak_rss_bytes() -> Int:
    var usage = List[Int64](length=32, fill=0)
    _ = external_call["getrusage", c_int](c_int(0), usage.unsafe_ptr())
    comptime if CompilationTarget.is_macos():
        return Int(usage[4])
    else:
        return Int(usage[4]) * 1024


def _write_source(
    path: String, catalog: FieldCatalog, count: Int, delta: Bool
) raises -> UInt32:
    # Generate the large fixture one record at a time so setup does not hide
    # compaction's peak. This independent fixture encoder writes frozen v5.
    var header = BinaryWriter()
    header.write_u32(UInt32(0x47534B41))
    header.write_u16(5)
    header.write_u16(UInt16(2 if delta else 1))
    header.write_u64(catalog.schema_revision)
    header.write_u32(field_catalog_checksum(catalog))
    header.write_u32(0)
    header.write_u64(UInt64(count))
    header.write_u64(UInt64(4097) if delta else UInt64(0))
    header.write_u64(UInt64(4097) if delta else UInt64(count))
    var bytes = header.take_bytes()
    var register = crc32_update(CRC32_INITIAL, Span(bytes)[4:])
    var point = PointState.live(
        0,
        1,
        1,
        [
            PointField(
                0,
                VectorValue.dense[DType.float32](
                    List[Float32](
                        length=4096, fill=Float32(2.0 if delta else 0.125)
                    )
                ),
            )
        ],
        [],
    )
    with open(path, "w") as file:
        file.write_all(bytes)
        for id in range(count):
            point.id = id
            point.sequence = UInt64(4097) if delta else UInt64(id + 1)
            point.document_sequence = point.sequence
            var record = encode_point_record(point, catalog)
            register = crc32_update(register, Span(record))
            file.write_all(record)
        var footer = BinaryWriter()
        footer.write_u32(~register)
        file.write_all(footer.take_bytes())
        sync_file(file)
    return ~register


def test_compaction_does_not_materialize_both_checkpoint_and_output() raises:
    var path = String(
        "/tmp/akasha-point-merge-memory-", Int(external_call["getpid", c_int]())
    )
    var store = PointStore.open(
        path, legacy_vector_fields(CollectionConfig.defaults(4096))
    )
    store.close()
    var catalog = load_field_catalog(path)
    var base_crc = _write_source(
        path + "/segment-base-4096.bin", catalog, 4096, False
    )
    var delta_crc = _write_source(
        path + "/point-delta-4097-2-0.bin", catalog, 1, True
    )
    var segments = List[SegmentDescriptor]()
    segments.append(
        SegmentDescriptor(1, 0, 4096, base_crc, "segment-base-4096.bin")
    )
    segments.append(
        SegmentDescriptor(0, 4097, 4097, delta_crc, "point-delta-4097-2-0.bin")
    )
    var manifest = Manifest.with_segments(4096, 2, 4097, segments^)
    publish_manifest(path, manifest)
    var inputs = capture_compaction_inputs(path, 4096)
    var before = _peak_rss_bytes()
    var output = build_compaction_output(path, 4096, inputs.value())
    var growth = _peak_rss_bytes() - before
    print("point compaction peak growth bytes:", growth)
    # Includes residency of the 64 MiB read-only input mapping. It must not
    # additionally retain a decoded table plus a complete encoded output.
    assert_true(
        growth < 96 * (1 << 20), "compaction retains full input/output buffers"
    )
    var file = MappedFile.open_readonly(path + "/" + output.segment_name)
    assert_equal(file.load_scalars[DType.uint64, 1](24), UInt64(4096))
    assert_equal(
        file.checksum(4, UInt64(file.byte_length() - 8)), output.checksum
    )
    assert_equal(
        file.load_scalars[DType.uint32, 1](file.byte_length() - 4),
        output.checksum,
    )
    discard_compaction_output(path, output)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
