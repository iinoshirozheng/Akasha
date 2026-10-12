from akasha import PersistentCollection
from akasha.common.config import CollectionConfig
from akasha.storage.committed_compaction import finish_compaction
from akasha.storage.filesystem import ensure_directory, path_exists, remove_file_if_exists
from akasha.storage.manifest import load_manifest
from std.os import listdir
from std.testing import assert_equal, assert_false, assert_true, TestSuite
from std.utils import BlockingScopedLock


def test_publication_defers_file_io_to_the_reclaim_phase() raises:
    var path = String("/tmp/akasha-unlocked-reclaim-publication")
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
    var inputs = collection._begin_compaction()
    assert_true(Bool(inputs))
    var output = collection._build_compaction(inputs.value())
    with BlockingScopedLock(collection._writer_lock[]):
        assert_true(finish_compaction(
            path, 1, inputs.value(), output, False, collection._pins,
            collection._retired, collection._read_generations,
        ))
    assert_equal(load_manifest(path, 1).generation, before.generation + 1)
    for index in range(len(before.segments)):
        assert_true(path_exists(path + "/" + before.segments[index].name))
    with BlockingScopedLock(collection._writer_lock[]):
        collection._retired[].reclaim(path)
    for index in range(len(before.segments)):
        assert_false(path_exists(path + "/" + before.segments[index].name))
    collection.close()
    var reopened = PersistentCollection.open_with_config(
        path, CollectionConfig.defaults(1), maintenance_library_path=""
    )
    assert_equal(reopened.get(1).value().vector[0], Float32(1))
    assert_equal(reopened.get(2).value().vector[0], Float32(2))
    reopened.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
