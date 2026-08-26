from akasha.index.flat import FlatIndex, SearchResult
from akasha.index.hnsw import HnswIndex
from std.sys.arg import argv


struct SplitMix64(Movable):
    """Small deterministic generator used only to make reproducible data."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_u64(mut self) -> UInt64:
        self.state += UInt64(0x9E3779B97F4A7C15)
        var value = self.state
        value = (value ^ (value >> 30)) * UInt64(0xBF58476D1CE4E5B9)
        value = (value ^ (value >> 27)) * UInt64(0x94D049BB133111EB)
        return value ^ (value >> 31)

    def uniform_signed(mut self) -> Float32:
        var bits = UInt32(self.next_u64() & UInt64(0x00FFFFFF))
        return Float32(bits) / 8_388_608.0 - 1.0


def recall_at_k(
    exact: List[SearchResult], approximate: List[SearchResult]
) -> Float64:
    if len(exact) == 0:
        return 1.0
    var matches = 0
    var counted = List[Int]()
    for expected in exact:
        for candidate in approximate:
            if candidate.id != expected.id:
                continue
            var duplicate = False
            for id in counted:
                if id == candidate.id:
                    duplicate = True
                    break
            if not duplicate:
                counted.append(candidate.id)
                matches += 1
            break
    return Float64(matches) / Float64(len(exact))


def _uniform_vector(mut rng: SplitMix64, dimension: Int) -> List[Float32]:
    var values = List[Float32](capacity=dimension)
    for _ in range(dimension):
        values.append(rng.uniform_signed())
    return values^


def _cluster_vector(
    mut rng: SplitMix64, point_id: Int, dimension: Int
) -> List[Float32]:
    var cluster = point_id % 8
    var values = List[Float32](capacity=dimension)
    for component in range(dimension):
        var center = Float32(0.0)
        if component % 8 == cluster:
            center = 0.75
        elif component % 8 == (cluster + 1) % 8:
            center = -0.75
        values.append(center + rng.uniform_signed() * 0.08)
    return values^


def _query_vector(
    mut rng: SplitMix64, query_id: Int, dimension: Int, clustered: Bool
) -> List[Float32]:
    if clustered:
        return _cluster_vector(rng, query_id, dimension)
    return _uniform_vector(rng, dimension)


def run_dataset(
    dataset: String,
    point_count: Int,
    dimension: Int,
    query_count: Int,
    k: Int,
    ef: Int,
    clustered: Bool,
) raises:
    var rng = SplitMix64(UInt64(0xA5A5D00D12345678))
    var exact = FlatIndex(dimension)
    var approximate = HnswIndex(dimension, m=16, max_level=16)

    for point_id in range(point_count):
        var values = _query_vector(rng, point_id, dimension, clustered)
        approximate.add(point_id, values)
        exact.add(point_id, values^)

    var recall_sum = Float64(0.0)
    for query_id in range(query_count):
        var query = _query_vector(
            rng, point_count + query_id, dimension, clustered
        )
        var ground_truth = exact.search_l2(query, k)
        var candidates = approximate.search_l2(query, k, ef)
        recall_sum += recall_at_k(ground_truth, candidates)

    var recall = recall_sum / Float64(query_count)
    # Task 13 wires actual HNSW traversal counters into these two fields.
    print(
        "dataset="
        + dataset
        + " points="
        + String(point_count)
        + " dimension="
        + String(dimension)
        + " k="
        + String(k)
        + " ef="
        + String(ef)
        + " recall="
        + String(recall)
        + " visited=0 distances=0"
    )


def main() raises:
    var smoke = False
    for argument in argv():
        if argument == "--smoke":
            smoke = True

    var point_count = 10_000
    var dimension = 64
    var query_count = 100
    var k = 10
    var ef = 64
    if smoke:
        point_count = 256
        dimension = 16
        query_count = 12
        k = 5
        ef = 32

    run_dataset("uniform", point_count, dimension, query_count, k, ef, False)
    run_dataset(
        "eight-cluster", point_count, dimension, query_count, k, ef, True
    )
