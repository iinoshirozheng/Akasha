"""Test conveniences for prepared entry/layer calls into production traversal."""
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_admission import HnswResultAdmission
from akasha.index.hnsw_core import HnswSearchAdmission
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_search import search_entry, search_level, _validate_search_boundary
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.hnsw_storage import HnswGraphAccess


def greedy_descent[GraphType: HnswGraphAccess, backend_tag: Int = -1](graph: GraphType, dispatcher: MetricDispatcher, query: List[Float32], entry: UInt32, level: Int, mut stats: HnswSearchStats) raises -> HnswHeapItem:
    var allowed = HnswSearchAdmission()
    var scratch = HnswSearchScratch()
    return search_entry[backend_tag=backend_tag](graph, dispatcher, query, entry, level, level - 1, allowed, scratch, stats)


def search_layer[GraphType: HnswGraphAccess, AdmissionType: HnswResultAdmission, backend_tag: Int = -1](graph: GraphType, dispatcher: MetricDispatcher, query: List[Float32], entry: UInt32, level: Int, k: Int, ef: Int, admission: AdmissionType, mut scratch: HnswSearchScratch, mut stats: HnswSearchStats) raises -> List[HnswHeapItem]:
    if k <= 0 or ef < k:
        raise Error("invalid test layer k/ef")
    _validate_search_boundary(graph, dispatcher, query, entry, level)
    admission.validate(graph.slot_count())
    if not graph.is_current(entry) or not admission._allows_item(entry, graph.id_at(entry)):
        return List[HnswHeapItem]()
    var scored = search_entry[backend_tag=backend_tag](graph, dispatcher, query, entry, level, level, admission, scratch, stats)
    var results = search_level[backend_tag=backend_tag](graph, dispatcher, query, scored, level, ef, admission, scratch, stats)
    while len(results) > k:
        _ = results.pop()
    stats.retained_candidates = len(results)
    return results^
