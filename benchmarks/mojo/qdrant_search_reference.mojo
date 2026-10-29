"""Single-entry Qdrant reference composed from production traversal primitives.

Query seed reuse is tested separately; this facade preserves the upstream
single-entry comparison used for construction. See qdrant_search_reference.md.
"""
from akasha.index.hnsw_query_scorer import MetricPointScorer
from akasha.query.control import QueryControl
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_admission import HnswResultAdmission
from akasha.index.hnsw_entries import HnswEntry
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.hnsw_storage import HnswGraphAccess
from akasha.index.hnsw_search import choose_entry, score_points, search_entry, search_level


def search[
    GraphType: HnswGraphAccess, AdmissionType: HnswResultAdmission, backend_tag: Int = -1
](
    graph: GraphType,
    dispatcher: MetricDispatcher,
    prepared: List[Float32],
    primary: List[HnswEntry],
    extra: List[HnswEntry],
    k: Int,
    ef: Int,
    allowed: AdmissionType,
    mut scratch: HnswSearchScratch,
    mut stats: HnswSearchStats,
    control: Optional[QueryControl] = None,
) raises -> List[HnswHeapItem]:
    """Eligible entry, filtered upper descent, filtered beam, final top-k."""
    if k < 0 or ef < 0:
        raise Error("HNSW k and ef cannot be negative")
    if k == 0:
        return List[HnswHeapItem]()
    graph.validate_search_ready()
    dispatcher.validate_prepared_vector(prepared)
    allowed.validate(graph.slot_count())
    var entry = choose_entry(graph, primary, extra, allowed)
    if not entry:
        return List[HnswHeapItem]()
    var current_item = search_entry[backend_tag=backend_tag](graph, MetricPointScorer(dispatcher, prepared.copy()), entry.value().slot, entry.value().level,
        0, allowed, scratch, stats,
        control=control,
    )
    var breadth = ef if ef >= k else k
    var results = search_level[backend_tag=backend_tag](graph, MetricPointScorer(dispatcher, prepared.copy()),
        current_item,
        0,
        breadth,
        allowed,
        scratch,
        stats,
        control=control,
    )
    while len(results) > k:
        _ = results.pop()
    stats.retained_candidates = len(results)
    return results^
