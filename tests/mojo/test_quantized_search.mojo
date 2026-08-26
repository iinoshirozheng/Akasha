from akasha import PersistentCollection
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_raises, TestSuite


def _reset(path: String) raises:
    ensure_directory(path)
    remove_file_if_exists(path + "/manifest.bin")
    remove_file_if_exists(path + "/manifest.bin.tmp")
    remove_file_if_exists(path + "/wal.bin")
    remove_file_if_exists(path + "/wal.bin.tmp")
    remove_file_if_exists(path + "/sparse.wal")
    remove_file_if_exists(path + "/sparse.wal.tmp")


def test_snapshot_sq8_exact_rerank_matches_scalar_oracle() raises:
    var path = String("/tmp/akasha-phase12-sq8-rerank")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    for id in range(1, 65):
        collection.upsert(
            id,
            [
                Float32(id % 11),
                Float32((id * 3) % 17),
                Float32((id * 7) % 13),
                Float32(id) / 10.0,
            ],
        )
    var snapshot = collection.snapshot()
    var query: List[Float32] = [3.2, 7.4, 5.1, 2.2]

    var exact_dot = snapshot.search_dot(query, 5)
    var exact_l2 = snapshot.search_l2(query, 5)
    var exact_cosine = snapshot.search_cosine(query, 5)
    var sq8_dot = snapshot.search_sq8_dot(query, 5, rerank_k=32)
    var sq8_l2 = snapshot.search_sq8_l2(query, 5, rerank_k=32)
    var sq8_cosine = snapshot.search_sq8_cosine(query, 5, rerank_k=32)
    for index in range(5):
        assert_equal(sq8_dot[index].id, exact_dot[index].id)
        assert_equal(sq8_l2[index].id, exact_l2[index].id)
        assert_equal(sq8_cosine[index].id, exact_cosine[index].id)
        assert_equal(sq8_dot[index].score, exact_dot[index].score)
        assert_equal(sq8_l2[index].score, exact_l2[index].score)
        assert_equal(sq8_cosine[index].score, exact_cosine[index].score)
    collection.close()


def test_snapshot_sq8_approximate_surface_and_validation() raises:
    var path = String("/tmp/akasha-phase12-sq8-validation")
    _reset(path)
    var collection = PersistentCollection.open(path, 2)
    collection.upsert(1, [1.0, 0.0])
    collection.upsert(2, [2.0, 0.0])
    collection.upsert(3, [0.0, 1.0])
    var snapshot = collection.snapshot()

    assert_equal(snapshot.search_sq8_dot([1.0, 0.0], 1)[0].id, 2)
    with assert_raises():
        _ = snapshot.search_sq8_dot([1.0, 0.0], 2, rerank_k=1)
    with assert_raises():
        _ = snapshot.search_sq8_l2([1.0], 1)
    collection.close()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
