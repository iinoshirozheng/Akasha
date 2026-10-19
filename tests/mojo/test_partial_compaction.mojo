from akasha import PersistentCollection
from akasha.common.config import CollectionConfig
from akasha.document.point_state import PointState
from akasha.storage.compaction import select_merge_range
from akasha.storage.committed_compaction import (
    capture_compaction_inputs, build_compaction_output, publish_compaction_output,
    discard_compaction_output,
)
from akasha.storage.filesystem import (
    ensure_directory, remove_file_if_exists, read_file_bytes, write_file_sync,
)
from akasha.storage.manifest import load_manifest, Manifest, SegmentDescriptor, publish_manifest
from akasha.storage.point_segment import decode_point_segment, encode_point_segment
from akasha.storage.point_recovery import load_point_checkpoint
from akasha.storage.checksum import BorrowedBinaryReader
from std.ffi import c_int, external_call
from std.memory import ArcPointer
from std.os import listdir
from std.testing import assert_equal, assert_false, assert_true, assert_raises, TestSuite
from test_field_envelopes import _catalog, _fixture
from test_point_merge import _install


def _path(label: String) raises -> String:
    var path = String("/tmp/akasha-partial-", Int(external_call["getpid", c_int]()), "-", label)
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)
    return path


def _config() -> CollectionConfig:
    var config = CollectionConfig.defaults(1)
    config.m = 2
    config.m0 = 2
    config.ef_construction = 2
    return config^


def test_automatic_merge_keeps_large_base_and_deletions_then_explicit_compact_folds_all() raises:
    var path = _path("inline")
    var collection = PersistentCollection.open_with_config(
        path, _config(), maintenance_library_path=""
    )
    for id in range(1, 129):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    var base = load_manifest(path, 1).segments[0].name.copy()
    collection.delete(1)
    collection.flush()
    var snapshot = collection.snapshot()
    collection.upsert(2, [200.0])
    collection.flush()
    collection.upsert(129, [129.0])
    collection.flush()
    collection.delete(3)
    collection.flush()
    var partial = load_manifest(path, 1)
    assert_equal(partial.segments[0].name, base)
    assert_true(len(partial.segments) > 1)
    assert_true(len(partial.segments) < 5)
    assert_equal(partial.last_sequence, UInt64(132))
    collection.close()
    assert_false(Bool(snapshot.get(1)))
    assert_equal(snapshot.get(2).value().vector[0], Float32(2))
    assert_equal(snapshot.get(3).value().vector[0], Float32(3))
    assert_false(Bool(snapshot.get(129)))
    snapshot.close()
    var reopened = PersistentCollection.open_with_config(
        path, _config(), maintenance_library_path=""
    )
    assert_false(Bool(reopened.get(1)))
    assert_false(Bool(reopened.get(3)))
    assert_equal(reopened.get(2).value().vector[0], Float32(200))
    assert_equal(reopened.get(129).value().vector[0], Float32(129))
    var backup = _path("inline-backup")
    _ = reopened.backup_to(backup)
    var restored = PersistentCollection.open_with_config(
        backup, _config(), maintenance_library_path=""
    )
    assert_false(Bool(restored.get(1)))
    assert_false(Bool(restored.get(3)))
    assert_equal(restored.get(2).value().vector[0], Float32(200))
    assert_equal(restored.get(129).value().vector[0], Float32(129))
    restored.close()
    reopened.compact()
    assert_equal(len(load_manifest(path, 1).segments), 1)
    reopened.close()
    var final_open = PersistentCollection.open_with_config(
        path, _config(), maintenance_library_path=""
    )
    assert_false(Bool(final_open.get(1)))
    assert_false(Bool(final_open.get(3)))
    assert_equal(final_open.get(2).value().vector[0], Float32(200))
    assert_equal(final_open.get(129).value().vector[0], Float32(129))
    final_open.close()



def test_worker_automatic_merge_keeps_base_and_explicit_request_folds_all() raises:
    var path = _path("worker")
    var collection = PersistentCollection.open_with_config(path, _config())
    assert_true(collection.background_maintenance_enabled())
    for id in range(1, 129):
        collection.upsert(id, [Float32(id)])
    collection.flush()
    var base = load_manifest(path, 1).segments[0].name.copy()
    for id in range(1, 5):
        collection.delete(id)
        collection.flush()
    assert_true(collection.wait_for_maintenance())
    var partial = load_manifest(path, 1)
    assert_equal(partial.segments[0].name, base)
    assert_true(len(partial.segments) > 1)
    assert_true(len(partial.segments) < 5)
    # Explicit scheduling is a full merge even below the automatic threshold.
    assert_true(collection.schedule_maintenance())
    assert_true(collection.wait_for_maintenance())
    assert_equal(len(load_manifest(path, 1).segments), 1)
    collection.close()
    var reopened = PersistentCollection.open_with_config(path, _config())
    for id in range(1, 5):
        assert_false(Bool(reopened.get(id)))
    assert_equal(reopened.get(5).value().vector[0], Float32(5))
    reopened.close()


def test_coalesced_requests_keep_explicit_full_merge_in_both_orders() raises:
    var collection = PersistentCollection.open_with_config(
        _path("requests"), _config(), maintenance_library_path=""
    )
    var state = collection._maintenance._state
    assert_false(Bool(state[].take_compaction_request()))
    state[].request_compaction(automatic=True)
    state[].request_compaction()
    assert_false(state[].take_compaction_request().value())
    state[].request_compaction()
    state[].request_compaction(automatic=True)
    assert_false(state[].take_compaction_request().value())
    state[].request_compaction(automatic=True)
    assert_true(state[].take_compaction_request().value())
    assert_false(Bool(state[].take_compaction_request()))
    collection.close()


def test_size_policy_bounds_space_and_runs_without_reordering_sequences() raises:
    assert_equal(select_merge_range([1000, 10, 10, 10, 10]), (1, 5))
    assert_equal(select_merge_range([1000, 100, 41, 10, 10, 10, 10]), (3, 7))
    assert_equal(select_merge_range([1000, 100, 101, 102, 1]), (1, 5))
    assert_equal(select_merge_range([1000, 100, 10, 1, 1, 1]), (2, 6))
    assert_equal(select_merge_range([100, 70, 70, 70, 70]), (0, 5))
    with assert_raises():
        _ = select_merge_range([UInt64(Int.MAX), 1, 1, 1, 1])


def test_partial_typed_merge_keeps_tombstones_rebases_and_rejects_replaced_inputs() raises:
    var path = _path("typed-rebase")
    var catalog = _catalog(True)
    var typed = decode_point_segment(_fixture("typed-base-v4.bin"), catalog)
    var point = typed.points[0].copy()
    point.id = 1
    point.sequence = 8
    var base: List[PointState] = [point.copy()]
    point.sequence = 9
    var first: List[PointState] = [point.copy()]
    var deleted: List[PointState] = [PointState.deleted(1, 10)]
    point.id = 2
    point.sequence = 11
    var third: List[PointState] = [point.copy()]
    point.id = 3
    point.sequence = 12
    var suffix: List[PointState] = [point.copy()]
    _install(path, catalog, [
        encode_point_segment(1, 0, 8, base, catalog),
        encode_point_segment(2, 9, 9, first, catalog),
        encode_point_segment(2, 10, 10, deleted, catalog),
        encode_point_segment(2, 11, 11, third, catalog),
        encode_point_segment(2, 12, 12, suffix, catalog),
    ])
    var dimension = catalog.field_at(0).dimension
    var inputs = capture_compaction_inputs(path, dimension)
    inputs.value().first = 1
    inputs.value().limit = 4
    var stale = capture_compaction_inputs(path, dimension)
    stale.value().first = 1
    stale.value().limit = 4
    var output = build_compaction_output(path, dimension, inputs.value())
    var stale_output = build_compaction_output(path, dimension, stale.value())
    var expected: List[PointState] = [deleted[0].copy(), third[0].copy()]
    assert_equal(
        read_file_bytes(path + "/" + output.segment_name),
        encode_point_segment(2, 9, 11, expected, catalog),
    )
    # Commit a newer tail while this job is built; its deletion must survive.
    var current = load_manifest(path, dimension)
    var newest = encode_point_segment(2, 13, 13, [PointState.deleted(2, 13)], catalog)
    var footer = BorrowedBinaryReader(Span(newest)[len(newest) - 4:])
    write_file_sync(path + "/segment-5.bin", newest)
    current.segments.append(SegmentDescriptor(0, 13, 13, footer.read_u32(), "segment-5.bin"))
    var descriptors = List[SegmentDescriptor]()
    for index in range(len(current.segments)):
        descriptors.append(current.segments[index].clone())
    var appended = Manifest.with_segments(dimension, current.generation + 1, 13, descriptors^)
    publish_manifest(path, appended)
    assert_true(Bool(publish_compaction_output(path, dimension, inputs.value(), output)))
    var published = load_manifest(path, dimension)
    assert_equal(len(published.segments), 4)
    assert_equal(published.segments[0].name, "segment-0.bin")
    assert_equal(published.segments[1].name, output.segment_name)
    assert_equal(published.segments[2].name, "segment-4.bin")
    assert_equal(published.segments[3].name, "segment-5.bin")
    assert_equal(published.last_sequence, UInt64(13))
    var manifest_bytes = read_file_bytes(path + "/manifest.bin")
    assert_false(Bool(publish_compaction_output(path, dimension, stale.value(), stale_output)))
    discard_compaction_output(path, stale_output)
    assert_equal(read_file_bytes(path + "/manifest.bin"), manifest_bytes)
    var owner = ArcPointer(catalog^)
    var recovered = load_point_checkpoint(path, published, owner.copy())
    assert_equal(
        encode_point_segment(1, 0, 13, recovered.live_points(), owner[]),
        encode_point_segment(1, 0, 13, suffix, owner[]),
    )


def test_partial_corruption_fails_before_output_and_keeps_authority() raises:
    var path = _path("corrupt")
    var catalog = _catalog()
    _install(path, catalog, [
        encode_point_segment(1, 0, 8, [PointState.live(1, 8, 0, [], [])], catalog),
        encode_point_segment(2, 9, 9, [PointState.deleted(1, 9)], catalog),
        encode_point_segment(2, 10, 10, [PointState.live(2, 10, 0, [], [])], catalog),
    ])
    var dimension = catalog.field_at(0).dimension
    var inputs = capture_compaction_inputs(path, dimension)
    inputs.value().first = 1
    var bytes = read_file_bytes(path + "/segment-1.bin")
    bytes[len(bytes) - 1] ^= 1
    write_file_sync(path + "/segment-1.bin", bytes)
    var before = read_file_bytes(path + "/manifest.bin")
    var count = len(listdir(path))
    with assert_raises():
        _ = build_compaction_output(path, dimension, inputs.value())
    assert_equal(read_file_bytes(path + "/manifest.bin"), before)
    assert_equal(read_file_bytes(path + "/segment-1.bin"), bytes)
    assert_equal(len(listdir(path)), count)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
