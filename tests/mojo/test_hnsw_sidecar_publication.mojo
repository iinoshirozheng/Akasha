from akasha import PersistentCollection
from akasha.storage.filesystem import (
    ensure_directory,
    path_exists,
    read_file_bytes,
    remove_file_if_exists,
    write_file_sync,
)
from akasha.storage.manifest import (
    load_manifest,
    Manifest,
    publish_manifest,
    SegmentDescriptor,
)
from std.ffi import c_int, external_call
from std.os import listdir
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def _reset(path: String) raises:
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)


def _collection(path: String) raises -> PersistentCollection:
    _reset(path)
    var collection = PersistentCollection.open(path, 1)
    for id in range(32):
        collection.upsert(id, [Float32(id + 1)])
    collection.flush()
    return collection^


def test_same_sequence_rebuild_publishes_new_file_and_retires_behind_pin() raises:
    var path = String("/tmp/akasha-56-sidecar-same-sequence")
    var collection = _collection(path)
    var before = load_manifest(path, 1)
    var old_name = before.hnsw_name.value().copy()
    var old_bytes = read_file_bytes(path + "/" + old_name)
    var snapshot = collection.snapshot()
    collection.rebuild_hnsw()
    collection.flush()
    var after = load_manifest(path, 1)
    assert_equal(after.format_version, 4)
    assert_equal(after.last_sequence, before.last_sequence)
    assert_equal(after.generation, before.generation + UInt64(1))
    assert_true(after.hnsw_name.value() != old_name)
    assert_equal(read_file_bytes(path + "/" + old_name), old_bytes)
    snapshot.close()
    collection.flush()
    assert_false(path_exists(path + "/" + old_name))
    assert_true(path_exists(path + "/" + after.hnsw_name.value()))
    collection.close()
    var reopened = PersistentCollection.open(path, 1)
    assert_true(reopened._hnsw_checkpoint_was_hit)
    assert_equal(reopened.search_dot_approx([1.0], 1, 64)[0].id, 31)
    reopened.close()


def test_downgrade_upgrade_retains_captured_sidecar_until_pin_release() raises:
    var path = String("/tmp/akasha-56-sidecar-downgrade-upgrade")
    var collection = _collection(path)
    var before = load_manifest(path, 1)
    var old_name = before.hnsw_name.value().copy()
    var snapshot = collection.snapshot()
    var maximum_bytes = collection._hnsw_sidecar_max_bytes_for_test
    collection._hnsw_checkpoint_was_hit = False
    collection._hnsw_sidecar_max_bytes_for_test = 160
    collection.flush()
    var downgraded = load_manifest(path, 1)
    assert_equal(downgraded.format_version, 2)
    assert_false(Bool(downgraded.hnsw_name))
    assert_true(path_exists(path + "/" + old_name))
    collection._hnsw_sidecar_max_bytes_for_test = maximum_bytes
    collection.flush()
    var upgraded = load_manifest(path, 1)
    assert_equal(upgraded.format_version, 4)
    assert_true(upgraded.hnsw_name.value() != old_name)
    assert_true(path_exists(path + "/" + old_name))
    snapshot.close()
    collection.flush()
    assert_false(path_exists(path + "/" + old_name))
    collection.close()


def test_failed_manifest_publish_never_overwrites_any_job_output() raises:
    var path = String("/tmp/akasha-56-sidecar-publish-failure")
    var collection = _collection(path)
    var before = load_manifest(path, 1)
    var prior_bytes = read_file_bytes(path + "/manifest.bin")
    var old_name = before.hnsw_name.value().copy()
    var first_output = "hnsw-32-" + String(before.generation + 1) + "-0.bin"
    collection.rebuild_hnsw()
    ensure_directory(path + "/manifest.bin.tmp")
    with assert_raises():
        collection.flush()
    assert_equal(read_file_bytes(path + "/manifest.bin"), prior_bytes)
    assert_true(path_exists(path + "/" + old_name))
    var orphan_bytes = read_file_bytes(path + "/" + first_output)
    var fault = path + "/manifest.bin.tmp"
    assert_equal(external_call["rmdir", c_int](fault.as_c_string_slice()), 0)
    collection.flush()
    var after = load_manifest(path, 1)
    assert_true(after.hnsw_name.value() != first_output)
    assert_equal(read_file_bytes(path + "/" + first_output), orphan_bytes)
    collection.close()


def test_reopen_removes_job_outputs_and_preserves_unknown_names() raises:
    var path = String("/tmp/akasha-56-sidecar-future-orphan")
    var collection = _collection(path)
    var manifest = load_manifest(path, 1)
    collection.close()
    var future = "hnsw-32-" + String(manifest.generation + 1) + "-0.bin"
    var kept: List[String] = [
        "hnsw-user.bin",
        "hnsw-999.bin",
        "hnsw-32-01-0.bin",
        "hnsw-32-0-0.bin",
        "hnsw-32-1-18446744073709551616.bin",
        "segment-compact-01-0.bin",
        "sparse-compact-1-user.bin",
        "segment-compact-1-0.bin.tmp.tmp",
    ]
    for name in [future, future + ".tmp"]:
        write_file_sync(path + "/" + name, [UInt8(1)])
    for name in kept:
        write_file_sync(path + "/" + name, [UInt8(1)])
    var reopened = PersistentCollection.open(path, 1)
    assert_true(reopened._hnsw_checkpoint_was_hit)
    assert_false(path_exists(path + "/" + future))
    assert_false(path_exists(path + "/" + future + ".tmp"))
    for name in kept:
        assert_true(path_exists(path + "/" + name))
    assert_true(path_exists(path + "/" + manifest.hnsw_name.value()))
    reopened.close()


def test_v3_checkpoint_migrates_on_same_sequence_rebuild() raises:
    var path = String("/tmp/akasha-56-sidecar-v3-migration")
    var collection = _collection(path)
    collection.close()
    var current = load_manifest(path, 1)
    var old_name = "hnsw-" + String(current.last_sequence) + ".bin"
    var old_bytes = read_file_bytes(path + "/" + current.hnsw_name.value())
    write_file_sync(path + "/" + old_name, old_bytes)
    var segments = List[SegmentDescriptor]()
    for index in range(len(current.segments)):
        segments.append(current.segments[index].clone())
    var legacy = Manifest.with_hnsw(
        1,
        current.generation,
        current.last_sequence,
        segments^,
        old_name,
        current.hnsw_checksum.value(),
        current.hnsw_config_fingerprint.value(),
        current.hnsw_point_count.value(),
    )
    publish_manifest(path, legacy)
    var reopened = PersistentCollection.open(path, 1)
    assert_true(reopened._hnsw_checkpoint_was_hit)
    assert_equal(load_manifest(path, 1).format_version, 3)
    var pinned = reopened.snapshot()
    reopened.rebuild_hnsw()
    reopened.flush()
    var migrated = load_manifest(path, 1)
    assert_equal(migrated.format_version, 4)
    assert_equal(migrated.last_sequence, legacy.last_sequence)
    assert_true(migrated.hnsw_name.value() != old_name)
    assert_equal(read_file_bytes(path + "/" + old_name), old_bytes)
    pinned.close()
    reopened.flush()
    assert_false(path_exists(path + "/" + old_name))
    reopened.close()
    var latest = PersistentCollection.open(path, 1)
    assert_true(latest._hnsw_checkpoint_was_hit)
    assert_equal(latest.get(31).value().vector[0], Float32(32))
    latest.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
