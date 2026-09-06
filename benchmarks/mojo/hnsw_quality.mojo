from akasha.common.config import CollectionConfig, MetricKind
from akasha.index.flat import FlatIndex, SearchResult
from akasha.index.hnsw import HnswIndex
from std.sys.arg import argv
from std.time import perf_counter_ns


comptime _SEED = UInt64(0xA5A5D00D12345678)
comptime _M = 24
comptime _M0 = 48
comptime _EF_CONSTRUCTION = 192


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


struct _QualityQuery(Movable):
    """One precomputed query and its untimed exact-search oracle."""

    var values: List[Float32]
    var ground_truth: List[SearchResult]

    def __init__(
        out self,
        var values: List[Float32],
        var ground_truth: List[SearchResult],
    ):
        self.values = values^
        self.ground_truth = ground_truth^


struct _AnnMeasurements(Movable):
    """Aggregate ANN-only timing and real traversal counters."""

    var recall_sum: Float64
    var total_visited: Int
    var total_distances: Int
    var search_elapsed_ns: Int

    def __init__(out self):
        self.recall_sum = 0.0
        self.total_visited = 0
        self.total_distances = 0
        self.search_elapsed_ns = 0


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


def _exact_search(
    index: FlatIndex,
    metric: MetricKind,
    query: List[Float32],
    k: Int,
) raises -> List[SearchResult]:
    if metric == MetricKind.dot():
        return index.search_dot(query, k)
    if metric == MetricKind.l2():
        return index.search_l2(query, k)
    return index.search_cosine(query, k)


def _packed_size_estimate(index: HnswIndex) -> Int:
    """Estimate serialized bytes from the live packed-tape lengths.

    This deliberately excludes allocator capacity and dictionary overhead. It
    is a stable layout estimate for comparing benchmark runs, not an RSS
    measurement or the size of a committed persistence format.
    """
    return (
        64
        + len(index.graph.ids) * 8
        + len(index.graph.levels) * 2
        + len(index.graph.current_flags) * 3
        + len(index.graph.vector_scalars) * 4
        + len(index.graph.neighbor_bases) * 8
        + len(index.graph.neighbor_count_bases) * 8
        + len(index.graph.neighbor_counts) * 4
        + len(index.graph.neighbor_slots) * 4
    )


def _run_approximate_queries(
    mut index: HnswIndex,
    queries: List[_QualityQuery],
    k: Int,
    ef: Int,
) raises -> _AnnMeasurements:
    """Time only ANN search calls over precomputed queries and oracles."""
    var measurements = _AnnMeasurements()
    for query_index in range(len(queries)):
        var search_start = perf_counter_ns()
        var candidates = index.search(
            queries[query_index].values, k, ef_search=ef
        )
        measurements.search_elapsed_ns += perf_counter_ns() - search_start

        # Stats reads, oracle comparison, and recall accounting are outside the
        # timed interval so local ANN latency measures only HnswIndex.search.
        measurements.total_visited += (
            index.last_search_stats.upper_visited
            + index.last_search_stats.base_visited
        )
        measurements.total_distances += (
            index.last_search_stats.distance_evaluations
        )
        measurements.recall_sum += recall_at_k(
            queries[query_index].ground_truth, candidates
        )
    return measurements^


def run_dataset(
    dataset: String,
    metric: MetricKind,
    point_count: Int,
    dimension: Int,
    query_count: Int,
    k: Int,
    ef: Int,
    clustered: Bool,
) raises:
    var rng = SplitMix64(_SEED)
    var exact = FlatIndex(dimension)
    var config = CollectionConfig.defaults(dimension)
    config.ann_metric = metric.copy()
    config.m = _M
    config.m0 = _M0
    config.ef_construction = _EF_CONSTRUCTION
    config.max_level = 16
    var approximate = HnswIndex(config)

    for point_id in range(point_count):
        var values = _query_vector(rng, point_id, dimension, clustered)
        approximate.add(point_id, values)
        exact.add(point_id, values^)

    # Prepare queries and exact ground truth before entering the ANN timing
    # seam. Dataset generation and FlatIndex work must never count as HNSW
    # query latency.
    var queries = List[_QualityQuery](capacity=query_count)
    for query_id in range(query_count):
        var query = _query_vector(
            rng, point_count + query_id, dimension, clustered
        )
        var ground_truth = _exact_search(exact, metric, query, k)
        queries.append(_QualityQuery(query^, ground_truth^))

    var measurements = _run_approximate_queries(approximate, queries, k, ef)
    var recall = measurements.recall_sum / Float64(query_count)
    var average_visited = Float64(measurements.total_visited) / Float64(
        query_count
    )
    var average_distances = Float64(measurements.total_distances) / Float64(
        query_count
    )
    var ann_ns_per_query = Float64(measurements.search_elapsed_ns) / Float64(
        query_count
    )
    print(
        "dataset="
        + dataset
        + " metric="
        + metric.name()
        + " scalar="
        + config.scalar_name()
        + " backend="
        + approximate.distance_backend.backend_name()
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
        + " build_distances="
        + String(approximate.build_stats.distance_evaluations)
        + " directed_edges="
        + String(approximate.build_stats.directed_edges)
        + " avg_visited="
        + String(average_visited)
        + " avg_search_distances="
        + String(average_distances)
        + " packed_size_estimate_bytes="
        + String(_packed_size_estimate(approximate))
        + " local_ann_search_ns_per_query="
        + String(ann_ns_per_query)
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

    for metric in [MetricKind.dot(), MetricKind.l2(), MetricKind.cosine()]:
        run_dataset(
            "uniform",
            metric,
            point_count,
            dimension,
            query_count,
            k,
            ef,
            False,
        )
        run_dataset(
            "eight-cluster",
            metric,
            point_count,
            dimension,
            query_count,
            k,
            ef,
            True,
        )
