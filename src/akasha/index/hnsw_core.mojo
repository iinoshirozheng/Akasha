from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.hnsw_storage import HnswStorage
from std.collections import Dict


struct HnswGreedyResult(Copyable, Movable):
    """The local minimum reached by one upper-layer greedy descent."""

    var slot: UInt32
    var distance: Float32

    def __init__(out self, slot: UInt32, distance: Float32):
        self.slot = slot
        self.distance = distance


struct HnswSearchAdmission(Movable):
    """Narrow slot-admission seam used until metadata bitmaps land in Task 15.

    The empty constructor is an allocation-free allow-all fast path. A caller
    may instead move in one stable list of slot flags; searches borrow that
    list and never clone or allocate an eligibility bitmap per query.
    """

    var _allow_all: Bool
    var _allowed_slots: List[Bool]

    def __init__(out self):
        self._allow_all = True
        self._allowed_slots = List[Bool]()

    def __init__(out self, var allowed_slots: List[Bool]):
        self._allow_all = False
        self._allowed_slots = allowed_slots^

    def validate(self, slot_count: Int) raises:
        if slot_count < 0:
            raise Error("HNSW admission slot count cannot be negative")
        if not self._allow_all and len(self._allowed_slots) != slot_count:
            raise Error("HNSW admission flags do not match graph slots")

    def allows(self, slot: UInt32) -> Bool:
        if self._allow_all:
            return True
        return self._allowed_slots[Int(slot)]


def _search_item_better(lhs: HnswHeapItem, rhs: HnswHeapItem) -> Bool:
    """Deterministic strict ordering by distance, public ID, then slot."""
    if lhs.distance != rhs.distance:
        return lhs.distance < rhs.distance
    if lhs.id != rhs.id:
        return lhs.id < rhs.id
    return lhs.slot < rhs.slot


def _validate_search_boundary(
    graph: HnswStorage,
    dispatcher: MetricDispatcher,
    query: List[Float32],
    entry: UInt32,
    level: Int,
) raises:
    """Validate all caller-owned state before scratch or stats are mutated."""
    dispatcher.require_supported_backend()
    if graph.slot_count() <= 0:
        raise Error("cannot search an empty HNSW graph")
    if graph.dimension <= 0 or graph.m <= 0 or graph.m0 <= 0:
        raise Error("HNSW graph configuration is invalid")
    if dispatcher.dimension() != graph.dimension:
        raise Error("metric dispatcher dimension does not match HNSW graph")
    # This validates finite values and the prepared-cosine unit-norm contract
    # without performing (or falsely counting) a graph distance evaluation.
    dispatcher._validate_prepared_values(query)
    if UInt64(entry) >= UInt64(graph.slot_count()):
        raise Error("HNSW entry slot out of bounds")
    if level < 0 or level > graph.level(entry):
        raise Error("HNSW entry does not own requested level")
    # Mutable storage permits low-level construction primitives. Validate the
    # entry adjacency up front, but do not run the O(nodes + edges) structural
    # audit on every query: construction/load boundaries own that audit.
    var edge_count = graph.neighbor_count(entry, level)
    for edge_index in range(edge_count):
        var neighbor = graph.neighbor_at(entry, level, edge_index)
        if graph.level(neighbor) < level:
            raise Error("HNSW edge targets a node below its graph level")


def greedy_descent(
    graph: HnswStorage,
    dispatcher: MetricDispatcher,
    query: List[Float32],
    entry: UInt32,
    level: Int,
    mut stats: HnswSearchStats,
) raises -> HnswGreedyResult:
    """Greedily descend one upper layer to a deterministic local minimum.

    Inactive historical nodes remain valid navigation points. Each distinct
    slot encountered during this phase is scored once and cached, even when
    graph adjacency exposes it from more than one visited node. Therefore
    ``upper_visited`` and ``distance_evaluations`` each increase once per
    distinct scored slot, including the entry; counters are additive across
    repeated upper-layer calls on the same stats object.
    """
    _validate_search_boundary(graph, dispatcher, query, entry, level)

    var current_slot = entry
    var current_distance = graph.distance_to_slot(dispatcher, query, entry)
    # Upper layers are sparse. Cache only the slots actually encountered,
    # avoiding an O(total_slots) allocation before a logarithmic descent.
    var distances = Dict[Int, Float32]()
    distances[Int(entry)] = current_distance
    stats.upper_visited += 1
    stats.distance_evaluations += 1

    while True:
        var current_item = HnswHeapItem(
            current_slot, graph.id_at(current_slot), current_distance
        )
        var best_item = current_item.copy()
        var count = graph.neighbor_count(current_slot, level)
        for edge_index in range(count):
            var neighbor = graph.neighbor_at(current_slot, level, edge_index)
            if graph.level(neighbor) < level:
                raise Error("HNSW edge targets a node below its graph level")
            var neighbor_index = Int(neighbor)
            var neighbor_distance: Float32
            if neighbor_index not in distances:
                neighbor_distance = graph.distance_to_slot(
                    dispatcher, query, neighbor
                )
                distances[neighbor_index] = neighbor_distance
                stats.upper_visited += 1
                stats.distance_evaluations += 1
            else:
                neighbor_distance = distances[neighbor_index]
            var neighbor_item = HnswHeapItem(
                neighbor,
                graph.id_at(neighbor),
                neighbor_distance,
            )
            if _search_item_better(neighbor_item, best_item):
                best_item = neighbor_item.copy()

        if not _search_item_better(best_item, current_item):
            break
        current_slot = best_item.slot
        current_distance = best_item.distance

    return HnswGreedyResult(current_slot, current_distance)


def _consider_result_admission(
    graph: HnswStorage,
    admission: HnswSearchAdmission,
    item: HnswHeapItem,
    ef: Int,
    mut scratch: HnswSearchScratch,
    mut stats: HnswSearchStats,
) raises:
    if not graph.is_current(item.slot):
        stats.inactive_rejections += 1
        return
    if not admission.allows(item.slot):
        stats.filtered_rejections += 1
        return
    scratch.results.offer(item, ef)


def search_layer(
    graph: HnswStorage,
    dispatcher: MetricDispatcher,
    query: List[Float32],
    entry: UInt32,
    level: Int,
    k: Int,
    ef: Int,
    admission: HnswSearchAdmission,
    mut scratch: HnswSearchScratch,
    mut stats: HnswSearchStats,
) raises -> List[HnswHeapItem]:
    """Search one HNSW layer and return up to ``k`` items best-first.

    Every first-seen slot is scored exactly once. Current/filter eligibility
    controls only result admission: rejected and inactive slots can still
    traverse the graph. Frontier growth follows the standard retained-radius
    rule and terminates only when its best unexplored distance is strictly
    greater than the worst retained distance. Equal-distance items remain
    traversable regardless of their deterministic result-order ID/slot ties.
    ``base_visited`` and ``distance_evaluations``
    increase once per first-seen scored slot, including the entry. A first-seen
    non-current slot increments only ``inactive_rejections``; a current but
    disallowed slot increments only ``filtered_rejections``. The final top-k
    return length replaces ``retained_candidates``; all other counters are
    additive so callers can aggregate upper and base phases in one object.
    """
    if k <= 0:
        raise Error("HNSW search k must be positive")
    if ef <= 0:
        raise Error("HNSW search ef must be positive")
    if ef < k:
        raise Error("HNSW search ef must be at least k")
    _validate_search_boundary(graph, dispatcher, query, entry, level)
    admission.validate(graph.slot_count())

    scratch.begin(graph.slot_count(), ef)
    _ = scratch.visit(entry)
    var entry_distance = graph.distance_to_slot(dispatcher, query, entry)
    var entry_item = HnswHeapItem(entry, graph.id_at(entry), entry_distance)
    stats.base_visited += 1
    stats.distance_evaluations += 1
    scratch.candidates.push(entry_item)
    _consider_result_admission(graph, admission, entry_item, ef, scratch, stats)

    while not scratch.candidates.is_empty():
        var candidate = scratch.candidates.pop()
        if (
            len(scratch.results) >= ef
            and candidate.distance > scratch.results.peek_worst().distance
        ):
            break

        var neighbor_count = graph.neighbor_count(candidate.slot, level)
        for edge_index in range(neighbor_count):
            var neighbor = graph.neighbor_at(candidate.slot, level, edge_index)
            if graph.level(neighbor) < level:
                raise Error("HNSW edge targets a node below its graph level")
            if not scratch.visit(neighbor):
                continue

            var distance = graph.distance_to_slot(dispatcher, query, neighbor)
            var item = HnswHeapItem(neighbor, graph.id_at(neighbor), distance)
            stats.base_visited += 1
            stats.distance_evaluations += 1

            _consider_result_admission(
                graph, admission, item, ef, scratch, stats
            )

            if (
                len(scratch.results) < ef
                or item.distance <= scratch.results.peek_worst().distance
            ):
                scratch.candidates.push(item)

    var best = scratch.results.take_sorted_best()
    while len(best) > k:
        _ = best.pop()
    stats.retained_candidates = len(best)
    return best^
