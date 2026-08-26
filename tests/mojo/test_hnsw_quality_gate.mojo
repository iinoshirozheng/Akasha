from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.flat import FlatIndex, SearchResult
from akasha.index.hnsw import HnswIndex
from std.testing import assert_true, TestSuite


comptime _SEED = UInt64(0xD1B54A32D192ED03)
comptime _DIMENSION = 64
comptime _POINT_COUNT = 8_192
comptime _QUERY_COUNT = 24
comptime _K = 10
comptime _EF_SEARCH = 64
comptime _MINIMUM_RECALL = 0.95
comptime _M = 24
comptime _M0 = 48
comptime _EF_CONSTRUCTION = 192


struct SplitMix64(Movable):
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


def _vector(mut rng: SplitMix64) -> List[Float32]:
    var values = List[Float32](capacity=_DIMENSION)
    for _ in range(_DIMENSION):
        values.append(rng.uniform_signed())
    return values^


def _recall_at_k(
    exact: List[SearchResult], approximate: List[SearchResult]
) -> Float64:
    var matches = 0
    for expected in exact:
        for candidate in approximate:
            if candidate.id == expected.id:
                matches += 1
                break
    return Float64(matches) / Float64(len(exact))


def _exact_search(
    index: FlatIndex, metric: MetricKind, query: List[Float32]
) raises -> List[SearchResult]:
    if metric == MetricKind.dot():
        return index.search_dot(query, _K)
    if metric == MetricKind.l2():
        return index.search_l2(query, _K)
    return index.search_cosine(query, _K)


def _quality_config(metric: MetricKind) -> CollectionConfig:
    var config = CollectionConfig.defaults(_DIMENSION)
    config.ann_metric = metric.copy()
    config.m = _M
    config.m0 = _M0
    config.ef_construction = _EF_CONSTRUCTION
    config.level_seed = UInt64(0xA5A5A5A5A5A5A5A5)
    return config^


def _measure_recall(metric: MetricKind) raises -> Float64:
    var rng = SplitMix64(_SEED)
    var exact = FlatIndex(_DIMENSION)
    var approximate = HnswIndex(_quality_config(metric))
    for point_id in range(_POINT_COUNT):
        var values = _vector(rng)
        approximate.add(point_id, values)
        exact.add(point_id, values^)

    var recall_sum = Float64(0.0)
    for _ in range(_QUERY_COUNT):
        var query = _vector(rng)
        var ground_truth = _exact_search(exact, metric, query)
        var candidates = approximate.search(query, _K, ef_search=_EF_SEARCH)
        recall_sum += _recall_at_k(ground_truth, candidates)
    return recall_sum / Float64(_QUERY_COUNT)


def _build_distances(point_count: Int) raises -> Int:
    var rng = SplitMix64(_SEED)
    var index = HnswIndex(_quality_config(MetricKind.l2()))
    for point_id in range(point_count):
        index.add(point_id, _vector(rng))
    return index.build_stats.distance_evaluations


def test_dot_recall_at_10_meets_f32_gate() raises:
    var recall = _measure_recall(MetricKind.dot())
    print("quality-gate metric=dot recall@10=", recall)
    assert_true(recall >= _MINIMUM_RECALL)


def test_l2_recall_at_10_meets_f32_gate() raises:
    var recall = _measure_recall(MetricKind.l2())
    print("quality-gate metric=l2 recall@10=", recall)
    assert_true(recall >= _MINIMUM_RECALL)


def test_cosine_recall_at_10_meets_f32_gate() raises:
    var recall = _measure_recall(MetricKind.cosine())
    print("quality-gate metric=cosine recall@10=", recall)
    assert_true(recall >= _MINIMUM_RECALL)


def test_construction_distance_growth_stays_subquadratic() raises:
    var n_distances = _build_distances(512)
    var twice_n_distances = _build_distances(1_024)
    var ratio = Float64(twice_n_distances) / Float64(n_distances)
    print(
        "quality-gate build-distances n=512 value=",
        n_distances,
        "2n=1024 value=",
        twice_n_distances,
        "ratio=",
        ratio,
    )
    assert_true(n_distances > 0)
    assert_true(ratio < 3.5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
