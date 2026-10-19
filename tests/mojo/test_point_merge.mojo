from akasha.document.point_state import PointField, PointState
from akasha.document.vector_schema import FieldCatalog
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from akasha.storage.checksum import BorrowedBinaryReader
from akasha.storage.committed_compaction import (
    capture_compaction_inputs,
    build_compaction_output,
    discard_compaction_output,
)
from akasha.storage.field_catalog import encode_field_catalog
from akasha.storage.filesystem import (
    ensure_directory,
    read_file_bytes,
    write_file_sync,
    atomic_replace,
)
from akasha.storage.manifest import (
    Manifest,
    SegmentDescriptor,
    publish_manifest,
    load_manifest,
)
from akasha.storage.point_recovery import load_point_checkpoint
from akasha.storage.point_merge import PointMerge
from akasha.storage.point_segment import (
    decode_point_segment,
    encode_point_segment,
    PointSegmentCursor,
)
from std.ffi import c_int, external_call
from std.memory import ArcPointer
from std.os import listdir
from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from test_field_envelopes import _catalog, _fixture, _crc


def _path(label: String) -> String:
    return String(
        "/tmp/akasha-point-merge-",
        Int(external_call["getpid", c_int]()),
        "-",
        label,
    )


def _install(
    path: String, catalog: FieldCatalog, segments: List[List[UInt8]]
) raises:
    ensure_directory(path)
    write_file_sync(path + "/collection.bin", encode_field_catalog(catalog))
    var descriptors = List[SegmentDescriptor]()
    var last = UInt64(0)
    for i in range(len(segments)):
        ref bytes = segments[i]
        var kind_reader = BorrowedBinaryReader(Span(bytes)[6:8])
        var kind = kind_reader.read_u16()
        var interval = BorrowedBinaryReader(Span(bytes)[32:48])
        var minimum = interval.read_u64()
        last = interval.read_u64()
        var footer = BorrowedBinaryReader(Span(bytes)[len(bytes) - 4 :])
        var name = String("segment-", i, ".bin")
        write_file_sync(path + "/" + name, bytes)
        descriptors.append(
            SegmentDescriptor(
                1 if kind == 1 else 0, minimum, last, footer.read_u32(), name
            )
        )
    var manifest = Manifest.with_segments(
        catalog.field_at(0).dimension, 1, last, descriptors^
    )
    publish_manifest(path, manifest)


def _assert_owned_equivalence(path: String, var catalog: FieldCatalog) raises:
    var dimension = catalog.field_at(0).dimension
    var owner = ArcPointer(catalog^)
    var manifest = load_manifest(path, dimension)
    var old = load_point_checkpoint(path, manifest, owner.copy())
    var expected = encode_point_segment(
        1, 0, manifest.last_sequence, old.live_points(), owner[]
    )
    var inputs = capture_compaction_inputs(path, dimension)
    var before_manifest = read_file_bytes(path + "/manifest.bin")
    var output = build_compaction_output(path, dimension, inputs.value())
    assert_equal(read_file_bytes(path + "/" + output.segment_name), expected)
    assert_equal(read_file_bytes(path + "/manifest.bin"), before_manifest)
    discard_compaction_output(path, output)


def test_merge_matches_owned_oracle_for_frozen_v4_and_typed_v5() raises:
    var plain = _catalog()
    var empty_base = encode_point_segment(1, 0, 7, [], plain)
    _install(_path("frozen"), plain, [empty_base^, _fixture("delta-v4.bin")])
    _assert_owned_equivalence(_path("frozen"), plain^)
    for name in [
        String("base-v4.bin"),
        String("typed-base-v4.bin"),
        String("empty-base-v4.bin"),
    ]:
        var catalog = _catalog(name != "base-v4.bin")
        var base = _fixture(name)
        var decoded = decode_point_segment(base, catalog)
        if decoded.last_sequence == UInt64.MAX:
            # The frozen typed fixture uses the maximum sequence, so no later
            # delta can exist. Exercise the merge writer directly on that run.
            var path = _path(name)
            _install(path, catalog, [base.copy()])
            var manifest = load_manifest(path, catalog.field_at(0).dimension)
            var merge = PointMerge(path, manifest, catalog)
            _ = merge.write_segment(path + "/merged.bin")
            assert_equal(
                read_file_bytes(path + "/merged.bin"),
                encode_point_segment(1, 0, UInt64.MAX, decoded.points, catalog),
            )
            continue
        var next = decoded.last_sequence + 1
        var delta = encode_point_segment(
            2, next, next, List[PointState](), catalog
        )
        var path = _path(name)
        _install(path, catalog, [base^, delta^])
        _assert_owned_equivalence(path, catalog^)


def test_signed_id_order_replacement_rebirth_and_all_deleted_output() raises:
    var catalog = _catalog()
    var base: List[PointState] = [
        PointState.live(Int.MIN, 8, 0, [], []),
        PointState.live(0, 9, 0, [], []),
        PointState.live(Int.MAX, 10, 0, [], []),
    ]
    var first: List[PointState] = [
        PointState.deleted(Int.MIN, 11),
        PointState.live(0, 12, 0, [], []),
        PointState.deleted(Int.MAX, 13),
    ]
    var second: List[PointState] = [
        PointState.live(Int.MIN, 14, 0, [], []),
        PointState.deleted(0, 15),
        PointState.live(Int.MAX, 16, 0, [], []),
    ]
    var segments = List[List[UInt8]]()
    segments.append(encode_point_segment(1, 0, 10, base, catalog))
    segments.append(encode_point_segment(2, 11, 13, first, catalog))
    segments.append(encode_point_segment(2, 14, 16, second, catalog))
    _install(_path("rebirth"), catalog, segments)
    _assert_owned_equivalence(_path("rebirth"), _catalog())
    var deleted: List[PointState] = [
        PointState.deleted(Int.MIN, 17),
        PointState.deleted(Int.MAX, 18),
    ]
    segments.append(encode_point_segment(2, 17, 18, deleted, catalog))
    _install(_path("deleted"), catalog, segments)
    var inputs = capture_compaction_inputs(
        _path("deleted"), catalog.field_at(0).dimension
    )
    var output = build_compaction_output(
        _path("deleted"), catalog.field_at(0).dimension, inputs.value()
    )
    assert_equal(
        read_file_bytes(_path("deleted") + "/" + output.segment_name),
        encode_point_segment(1, 0, 18, [], catalog),
    )
    discard_compaction_output(_path("deleted"), output)


def test_overwritten_crc_valid_invalid_record_is_still_rejected() raises:
    var catalog = _catalog()
    var zero: List[PointState] = [
        PointState.live(
            7,
            8,
            0,
            [PointField(1, VectorValue.sparse([SparseElement(9, 0)]))],
            [],
        )
    ]
    var newer: List[PointState] = [PointState.live(7, 9, 0, [], [])]
    for variant in range(2):
        var base = encode_point_segment(1, 0, 8, zero, catalog)
        if variant == 0:
            base[
                4
            ] = 4  # Obsolete v4 record still must reject a zero sparse weight.
        else:
            base[
                53
            ] = 1  # CRC-correct unknown point flags, despite replacement.
        _crc(base)
        var delta = encode_point_segment(2, 9, 9, newer, catalog)
        var path = _path(String("invalid-", variant))
        _install(path, catalog, [base.copy(), delta.copy()])
        var inputs = capture_compaction_inputs(
            path, catalog.field_at(0).dimension
        )
        var manifest = read_file_bytes(path + "/manifest.bin")
        var before_names = listdir(path)
        with assert_raises():
            _ = build_compaction_output(
                path, catalog.field_at(0).dimension, inputs.value()
            )
        assert_equal(read_file_bytes(path + "/manifest.bin"), manifest)
        assert_equal(read_file_bytes(path + "/segment-0.bin"), base)
        assert_equal(read_file_bytes(path + "/segment-1.bin"), delta)
        assert_equal(len(listdir(path)), len(before_names))


def test_cursor_rewind_pins_original_inode_and_returns_owned_records() raises:
    var catalog = _catalog()
    var path = _path("rewind.bin")
    var bytes = _fixture("base-v4.bin")
    write_file_sync(path, bytes)
    var expected = decode_point_segment(bytes, catalog)
    var cursor = PointSegmentCursor(path, catalog)
    var first = cursor.read_next()
    assert_true(Bool(first))
    write_file_sync(path + ".tmp", [UInt8(0)])
    atomic_replace(path + ".tmp", path)
    cursor.rewind()
    var points = List[PointState]()
    while True:
        var point = cursor.read_next()
        if not point:
            break
        points.append(point.take())
    assert_equal(
        encode_point_segment(
            expected.kind,
            expected.min_sequence,
            expected.last_sequence,
            points,
            catalog,
        ),
        encode_point_segment(
            expected.kind,
            expected.min_sequence,
            expected.last_sequence,
            expected.points,
            catalog,
        ),
    )
    assert_equal(first.value().id, expected.points[0].id)


def test_merge_preserves_strict_cross_run_point_version_validation() raises:
    var catalog = _catalog()
    var base: List[PointState] = [PointState.live(7, 8, 0, [], [])]
    var next: List[PointState] = [PointState.live(7, 9, 0, [], [])]
    var path = _path("versions")
    _install(
        path,
        catalog,
        [
            encode_point_segment(1, 0, 8, base, catalog),
            encode_point_segment(2, 9, 9, next, catalog),
        ],
    )
    for sequence in [UInt64(7), UInt64(8)]:
        var manifest = load_manifest(path, catalog.field_at(0).dimension)
        var stale: List[PointState] = [PointState.live(7, sequence, 0, [], [])]
        var bytes = encode_point_segment(2, sequence, 9, stale, catalog)
        write_file_sync(path + "/segment-1.bin", bytes)
        var footer = BorrowedBinaryReader(Span(bytes)[len(bytes) - 4 :])
        # Match the captured descriptor to the deliberately overlapping input.
        # Both merge APIs must still enforce increasing versions per point.
        manifest.segments[1].min_sequence = sequence
        manifest.segments[1].checksum = footer.read_u32()
        with assert_raises(contains="versions do not increase"):
            _ = load_point_checkpoint(path, manifest, ArcPointer(_catalog()))
        with assert_raises(contains="versions do not increase"):
            _ = PointMerge(path, manifest, catalog)


def test_merge_many_segments_matches_owned_checkpoint() raises:
    var catalog = _catalog()
    var segments = List[List[UInt8]]()
    for index in range(64):
        var sequence = UInt64(index + 8)
        var points: List[PointState] = [
            PointState.live(index % 7, sequence, 0, [], [])
        ]
        segments.append(
            encode_point_segment(
                1 if index == 0 else 2,
                0 if index == 0 else sequence,
                sequence,
                points,
                catalog,
            )
        )
    var path = _path("many-segments")
    _install(path, catalog, segments)
    _assert_owned_equivalence(path, catalog^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
