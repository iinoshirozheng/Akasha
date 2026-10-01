struct HnswSearchStats(Movable, Writable):
    """Per-query counters and execution-path labels for HNSW search."""

    var requested_ef: Int
    var effective_ef: Int
    var widening_rounds: Int
    var upper_visited: Int
    var base_visited: Int
    var distance_evaluations: Int
    var retained_candidates: Int
    var reranked_candidates: Int
    var filtered_rejections: Int
    var inactive_rejections: Int
    var base_candidates: Int
    var delta_candidates: Int
    var ivf_partitions: Int
    var ivf_probed_partitions: Int
    var backend_name: String
    var metric_name: String
    var scalar_name: String
    var storage_name: String
    var fallback_reason: String

    def __init__(out self):
        self.requested_ef = 0
        self.effective_ef = 0
        self.widening_rounds = 0
        self.upper_visited = 0
        self.base_visited = 0
        self.distance_evaluations = 0
        self.retained_candidates = 0
        self.reranked_candidates = 0
        self.filtered_rejections = 0
        self.inactive_rejections = 0
        self.base_candidates = 0
        self.delta_candidates = 0
        self.ivf_partitions = 0
        self.ivf_probed_partitions = 0
        self.backend_name = String()
        self.metric_name = String()
        self.scalar_name = String()
        self.storage_name = String()
        self.fallback_reason = String()

    def reset(mut self):
        self.requested_ef = 0
        self.effective_ef = 0
        self.widening_rounds = 0
        self.upper_visited = 0
        self.base_visited = 0
        self.distance_evaluations = 0
        self.retained_candidates = 0
        self.reranked_candidates = 0
        self.filtered_rejections = 0
        self.inactive_rejections = 0
        self.base_candidates = 0
        self.delta_candidates = 0
        self.ivf_partitions = 0
        self.ivf_probed_partitions = 0
        self.backend_name = String()
        self.metric_name = String()
        self.scalar_name = String()
        self.storage_name = String()
        self.fallback_reason = String()


struct HnswBuildStats(Movable, Writable):
    """Aggregate counters describing one materialized HNSW graph."""

    var slot_count: Int
    var inactive_slots: Int
    var maximum_level: Int
    var directed_edges: Int
    var distance_evaluations: Int
    var serialized_bytes: Int

    def __init__(out self):
        self.slot_count = 0
        self.inactive_slots = 0
        self.maximum_level = 0
        self.directed_edges = 0
        self.distance_evaluations = 0
        self.serialized_bytes = 0

    def active_slots(self) -> Int:
        return self.slot_count - self.inactive_slots

    def reset(mut self):
        self.slot_count = 0
        self.inactive_slots = 0
        self.maximum_level = 0
        self.directed_edges = 0
        self.distance_evaluations = 0
        self.serialized_bytes = 0


def copy_search_stats(stats: HnswSearchStats) -> HnswSearchStats:
    var result = HnswSearchStats()
    result.requested_ef = stats.requested_ef
    result.effective_ef = stats.effective_ef
    result.widening_rounds = stats.widening_rounds
    result.upper_visited = stats.upper_visited
    result.base_visited = stats.base_visited
    result.distance_evaluations = stats.distance_evaluations
    result.retained_candidates = stats.retained_candidates
    result.reranked_candidates = stats.reranked_candidates
    result.filtered_rejections = stats.filtered_rejections
    result.inactive_rejections = stats.inactive_rejections
    result.base_candidates = stats.base_candidates
    result.delta_candidates = stats.delta_candidates
    result.ivf_partitions = stats.ivf_partitions
    result.ivf_probed_partitions = stats.ivf_probed_partitions
    result.backend_name = stats.backend_name.copy()
    result.metric_name = stats.metric_name.copy()
    result.scalar_name = stats.scalar_name.copy()
    result.storage_name = stats.storage_name.copy()
    result.fallback_reason = stats.fallback_reason.copy()
    return result^
