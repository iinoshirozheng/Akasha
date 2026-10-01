from akasha.document.point_state import PointMutation, PointState
from akasha.document.vector_schema import FieldCatalog
from akasha.storage.field_catalog import decode_field_catalog_bytes
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    write_file_sync,
)
from akasha.storage.manifest import (
    Manifest,
    SegmentDescriptor,
    publish_manifest,
)
from akasha.storage.point_segment import (
    decode_point_segment,
    encode_point_segment,
)
from akasha.storage.point_wal import encode_point_batch
from akasha.storage.point_recovery import preflight_point_authority
from std.ffi import c_int, external_call
from std.memory import ArcPointer
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)


def _catalog() raises -> ArcPointer[FieldCatalog]:
    return ArcPointer(
        decode_field_catalog_bytes(
            read_file_bytes("tests/fixtures/field-catalog/named-f32-v2.bin")
        )
    )


def _path(name: String) raises -> String:
    var path = String(
        "/tmp/akasha-point-recovery-",
        Int(external_call["getpid", c_int]()),
        "-",
        name,
    )
    ensure_directory(path)
    return path


def _checkpoint(path: String, catalog: FieldCatalog) raises:
    var base = read_file_bytes("tests/fixtures/field-envelopes/base-v4.bin")
    var base_checksum = decode_point_segment(base, catalog).checksum
    write_file_sync(path + "/segment-base-10.bin", base)
    var states: List[PointState] = [
        PointState.deleted(-42, 11),
        PointState.live(5, 12, 0, [], []),
    ]
    var delta = encode_point_segment(2, 11, 12, states, catalog)
    var delta_checksum = decode_point_segment(delta, catalog).checksum
    write_file_sync(path + "/segment-delta-12.bin", delta)
    var descriptors: List[SegmentDescriptor] = [
        SegmentDescriptor(1, 0, 10, base_checksum, "segment-base-10.bin"),
        SegmentDescriptor(0, 11, 12, delta_checksum, "segment-delta-12.bin"),
    ]
    var manifest = Manifest.with_segments(3, 2, 12, descriptors^)
    publish_manifest(path, manifest)


def test_point_base_and_delta_recover_latest_complete_states_before_wal() raises:
    var path = _path("base-delta")
    var catalog = _catalog()
    _checkpoint(path, catalog[])
    var mutations: List[PointMutation] = [PointMutation.delete(Int.MAX)]
    write_file_sync(
        path + "/wal.bin", encode_point_batch(13, mutations, catalog[])
    )
    var result = preflight_point_authority(path, catalog.copy())
    assert_equal(result.generation, UInt64(2))
    assert_equal(result.snapshot_sequence, UInt64(12))
    assert_equal(result.points.value().last_sequence(), UInt64(13))
    assert_equal(result.points.value().live_count(), 2)
    assert_false(Bool(result.points.value().get(-42)))
    assert_false(Bool(result.points.value().get(Int.MAX)))
    assert_true(Bool(result.points.value().get(0)))
    assert_true(Bool(result.points.value().get(5)))


def test_retained_complete_batches_are_validated_but_not_applied_twice() raises:
    var path = _path("retained")
    var catalog = _catalog()
    _checkpoint(path, catalog[])
    var retained = read_file_bytes(
        "tests/fixtures/field-envelopes/combined-wal-v4.bin"
    )
    retained.append(0xAB)
    write_file_sync(path + "/wal.bin", retained)
    var result = preflight_point_authority(path, catalog.copy())
    assert_equal(result.points.value().last_sequence(), UInt64(12))
    assert_false(Bool(result.points.value().get(-42)))
    assert_equal(
        result.points.value().get(Int.MAX).value().sequence, UInt64(10)
    )
    assert_equal(result.wal_valid_length, len(retained) - 1)
    assert_equal(read_file_bytes(path + "/wal.bin"), retained)
    retained[40] ^= 1
    write_file_sync(path + "/wal.bin", retained)
    with assert_raises():
        _ = preflight_point_authority(path, catalog.copy())
    assert_equal(read_file_bytes(path + "/wal.bin"), retained)


def test_manifest_binding_mismatch_and_late_segment_corruption_do_not_repair_wal() raises:
    var catalog = _catalog()
    for changed in range(3):
        var path = _path("corrupt-" + String(changed))
        _checkpoint(path, catalog[])
        var bytes = read_file_bytes(path + "/segment-delta-12.bin")
        if changed == 0:
            bytes[len(bytes) - 1] ^= 1
        elif changed == 1:
            var states: List[PointState] = [PointState.deleted(-42, 11)]
            bytes = encode_point_segment(2, 11, 12, states, catalog[])
        else:
            _ = bytes.pop()
        write_file_sync(path + "/segment-delta-12.bin", bytes)
        var torn: List[UInt8] = [1, 2, 3]
        write_file_sync(path + "/wal.bin", torn)
        with assert_raises():
            _ = preflight_point_authority(path, catalog.copy())
        assert_equal(read_file_bytes(path + "/wal.bin"), torn)


def test_new_checkpoint_rejects_new_mutations_in_legacy_sparse_wal() raises:
    var path = _path("sparse-after-cutover")
    var catalog = _catalog()
    _checkpoint(path, catalog[])
    from akasha.storage.sparse_store import append_sparse_wal, SparseWalRecord
    from akasha.index.sparse import SparseElement

    append_sparse_wal(
        path + "/sparse.wal",
        SparseWalRecord.upsert(8, 0, [SparseElement(1, 2)]),
    )
    var original = read_file_bytes(path + "/sparse.wal")
    with assert_raises():
        _ = preflight_point_authority(path, catalog.copy())
    assert_equal(read_file_bytes(path + "/sparse.wal"), original)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
