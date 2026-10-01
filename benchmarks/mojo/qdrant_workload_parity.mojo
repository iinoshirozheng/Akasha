"""Check shared Python inputs against the existing native quality generator."""

from hnsw_quality import SplitMix64, _query_vector
from std.python import Python, PythonObject
from std.testing import assert_equal


def _check(actual: List[Float32], expected: PythonObject) raises:
    for component in range(len(actual)):
        assert_equal(actual[component], Float32(py=expected[component]))


def main() raises:
    var module = Python.import_module("benchmarks.qdrant_workload")
    var dimensions: List[Int] = [8, 128, 1536]
    var seeds: List[Int] = [12345, 67890]
    for seed in seeds:
        for dimension in dimensions:
            var data = module.synthetic_workload(128, dimension, 2, seed)
            var expected_ids = data.ids.tolist()
            var vectors = data.vectors.tolist()
            var updates = data.updates.tolist()
            var queries = data.queries.tolist()
            var deleted = data.deletes.tolist()
            var rng = SplitMix64(UInt64(seed))
            var ids = List[Int]()
            for id in range(128):
                ids.append(id)
            for index in range(127, 0, -1):
                ids.swap_elements(index, Int(rng.next_u64() % UInt64(index + 1)))
            for ordinal in range(128):
                assert_equal(ids[ordinal], Int(py=expected_ids[ordinal]))
                _check(_query_vector(rng, ids[ordinal], dimension, False), vectors[ordinal])
            for ordinal in range(12):
                _check(_query_vector(rng, ids[ordinal], dimension, False), updates[ordinal])
            for ordinal in range(4):
                assert_equal(ids[64 + ordinal * 20], Int(py=deleted[ordinal]))
            for mode in range(4):
                for ordinal in range(5):
                    _check(_query_vector(rng, ordinal, dimension, False), queries[mode][ordinal])
    print("PASS: six native/Python workload parity cases")
