from akasha import PersistentCollection
from akasha.index.quantization import PqCodebook, PqIndex
from akasha.storage.filesystem import ensure_directory, remove_file_if_exists
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def _training_vectors() -> List[List[Float32]]:
    var vectors = List[List[Float32]]()
    for row in range(16):
        vectors.append(
            [
                Float32(row % 4) + 0.25,
                Float32((row * 3) % 7),
                Float32((row * 5) % 11),
                Float32(row) / 3.0,
            ]
        )
    return vectors^


def _reset(path: String) raises:
    ensure_directory(path)
    remove_file_if_exists(path + "/manifest.bin")
    remove_file_if_exists(path + "/manifest.bin.tmp")
    remove_file_if_exists(path + "/wal.bin")
    remove_file_if_exists(path + "/wal.bin.tmp")
    remove_file_if_exists(path + "/sparse.wal")
    remove_file_if_exists(path + "/sparse.wal.tmp")


def test_pq_training_and_codes_are_deterministic() raises:
    var vectors = _training_vectors()
    var lhs = PqCodebook.train(vectors, 2, 4, iterations=6)
    var rhs = PqCodebook.train(vectors, 2, 4, iterations=6)
    assert_equal(lhs.version(), UInt32(1))
    assert_equal(lhs.dimension(), 4)
    assert_equal(lhs.subquantizer_count(), 2)
    assert_equal(lhs.centroid_count(), 4)
    var lhs_code = lhs.encode(vectors[7])
    var rhs_code = rhs.encode(vectors[7])
    assert_equal(len(lhs_code), 2)
    assert_equal(lhs_code[0], rhs_code[0])
    assert_equal(lhs_code[1], rhs_code[1])
    assert_true(Int(lhs_code[0]) < 4)


def test_pq_index_searches_all_metrics() raises:
    var vectors = _training_vectors()
    var ids = List[Int](capacity=len(vectors))
    for index in range(len(vectors)):
        ids.append(index + 1)
    var index = PqIndex.build(ids, vectors, 2, 8, iterations=8)
    var query = vectors[9].copy()
    assert_equal(index.search_l2(query, 1)[0].id, 10)
    assert_true(len(index.search_dot(query, 3)) == 3)
    assert_true(len(index.search_cosine(query, 3)) == 3)
    assert_equal(index.encoded_bytes(), len(vectors) * 2)


def test_pq_snapshot_rerank_matches_exact_oracle() raises:
    var path = String("/tmp/akasha-phase12-pq-rerank")
    _reset(path)
    var collection = PersistentCollection.open(path, 4)
    var vectors = _training_vectors()
    for index in range(len(vectors)):
        collection.upsert(index + 1, vectors[index].copy())
    var snapshot = collection.snapshot()
    var query: List[Float32] = [2.2, 3.1, 4.3, 1.7]
    var exact_l2 = snapshot.search_l2(query, 4)
    var exact_dot = snapshot.search_dot(query, 4)
    var exact_cosine = snapshot.search_cosine(query, 4)
    var pq_l2 = snapshot.search_pq_l2(
        query,
        4,
        subquantizers=2,
        centroids=8,
        rerank_k=16,
    )
    var pq_dot = snapshot.search_pq_dot(
        query,
        4,
        subquantizers=2,
        centroids=8,
        rerank_k=16,
    )
    var pq_cosine = snapshot.search_pq_cosine(
        query,
        4,
        subquantizers=2,
        centroids=8,
        rerank_k=16,
    )
    for index in range(4):
        assert_equal(pq_l2[index].id, exact_l2[index].id)
        assert_equal(pq_l2[index].score, exact_l2[index].score)
        assert_equal(pq_dot[index].id, exact_dot[index].id)
        assert_equal(pq_dot[index].score, exact_dot[index].score)
        assert_equal(pq_cosine[index].id, exact_cosine[index].id)
        assert_equal(pq_cosine[index].score, exact_cosine[index].score)
    collection.close()


def test_pq_rejects_malformed_configuration() raises:
    var vectors = _training_vectors()
    with assert_raises():
        _ = PqCodebook.train(vectors, 3, 4)
    with assert_raises():
        _ = PqCodebook.train(vectors, 2, 0)
    with assert_raises():
        _ = PqCodebook.train(vectors, 2, 257)
    with assert_raises():
        _ = PqCodebook.train(vectors, 2, 4, iterations=0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
