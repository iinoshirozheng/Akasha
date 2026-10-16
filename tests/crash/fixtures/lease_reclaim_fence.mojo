from akasha import PersistentCollection
from akasha.common.config import CollectionConfig
from akasha.storage.file_leases import reclaim_unreferenced_job_files
from akasha.storage.filesystem import ensure_directory, path_exists, remove_file_if_exists, write_file_sync
from akasha.storage.manifest import load_manifest
from std.os import listdir
from std.sys.arg import argv
from std.testing import assert_equal, assert_false, assert_true


def main() raises:
    var path = argv()[1]
    ensure_directory(path)
    for name in listdir(path):
        remove_file_if_exists(path + "/" + name)
    var collection = PersistentCollection.open_with_config(
        path, CollectionConfig.defaults(1), maintenance_library_path=""
    )
    collection.upsert(1, [1.0])
    collection.flush()
    collection.upsert(2, [2.0])
    collection.flush()
    var before = load_manifest(path, 1)
    var snapshot = collection.snapshot()
    collection.compact()
    for index in range(len(before.segments)):
        assert_true(path_exists(path + "/" + before.segments[index].name))
    # The loader fixture fails exactly the next directory fsync. Regular
    # file fsyncs (including this marker) are unaffected.
    write_file_sync(path + "/fail-sync", [UInt8(1)])
    snapshot.close()
    assert_false(path_exists(path + "/fail-sync"))
    assert_equal(collection._pins[].active_count(), 0)
    assert_true(collection._pins[].cleanup_error().byte_length() > 0)
    for index in range(len(before.segments)):
        if not path_exists(path + "/" + before.segments[index].name):
            raise Error("retired input disappeared before authority sync succeeded")
    # A later explicit retry, after the one-shot fault, can reclaim safely.
    collection.flush()
    for index in range(len(before.segments)):
        assert_false(path_exists(path + "/" + before.segments[index].name))
    collection.close()
    var reopened = PersistentCollection.open_with_config(
        path, CollectionConfig.defaults(1), maintenance_library_path=""
    )
    assert_equal(reopened.get(1).value().vector[0], Float32(1))
    assert_equal(reopened.get(2).value().vector[0], Float32(2))
    # Open-time orphan cleanup has the same authority-before-delete boundary.
    # This handle retains the source writer lock without a maintenance worker.
    var orphan = path + "/point-base-2-99-1.bin"
    write_file_sync(orphan, [UInt8(1)])
    write_file_sync(path + "/fail-sync", [UInt8(1)])
    var failed = False
    try:
        reclaim_unreferenced_job_files(path, 1)
    except:
        failed = True
    assert_true(failed)
    assert_false(path_exists(path + "/fail-sync"))
    assert_true(path_exists(orphan))
    reclaim_unreferenced_job_files(path, 1)
    assert_false(path_exists(orphan))
    reopened.close()
    var final_open = PersistentCollection.open_with_config(
        path, CollectionConfig.defaults(1), maintenance_library_path=""
    )
    assert_equal(final_open.get(1).value().vector[0], Float32(1))
    assert_equal(final_open.get(2).value().vector[0], Float32(2))
    final_open.close()
    print("durability fence fault probe passed")
