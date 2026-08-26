from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_heap import HnswHeapItem
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswBuildStats, HnswSearchStats
from akasha.index.hnsw_storage import HnswStorage
from std.collections import Dict
from std.math import isfinite


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


def _sort_neighbor_candidates(mut candidates: List[HnswHeapItem]):
    """Insertion-sort build candidates by the complete stable graph key."""
    for index in range(1, len(candidates)):
        var current = index
        while current > 0 and _search_item_better(
            candidates[current], candidates[current - 1]
        ):
            candidates.swap_elements(current, current - 1)
            current -= 1


def select_neighbors_heuristic(
    graph: HnswStorage,
    dispatcher: MetricDispatcher,
    candidates: List[HnswHeapItem],
    excluded_slot: Optional[UInt32],
    capacity: Int,
    keep_pruned_connections: Bool,
    mut stats: HnswBuildStats,
) raises -> List[UInt32]:
    """Select deterministic, geometrically diverse current graph slots.

    Candidate distances are caller-cached canonical query-to-candidate
    distances and are never recomputed here. Inputs are first validated and
    ordered by ``(distance, public ID, slot)``. Duplicate slots and the
    optional query/self slot are then removed. Historical (deleted or
    replaced) candidates are rejected at this construction boundary rather
    than silently linked into new adjacency.

    A candidate is diverse when no already-selected neighbor is strictly
    closer to it than the query is. Equality is deliberately accepted. Pair
    distances read the storage's flat vector tape directly, without creating
    per-pair vector lists. Evaluation increments are accumulated locally and
    committed to ``stats`` only after a successful selection, so validation
    and corrupt-distance failures leave all build counters unchanged.
    """
    if capacity < 0:
        raise Error("HNSW neighbor selection capacity cannot be negative")
    dispatcher.require_supported_backend()
    if graph.dimension <= 0 or graph.m <= 0 or graph.m0 <= 0:
        raise Error("HNSW graph configuration is invalid")
    if dispatcher.dimension() != graph.dimension:
        raise Error("metric dispatcher dimension does not match HNSW graph")

    var has_excluded = Bool(excluded_slot)
    var excluded = UInt32(0)
    if has_excluded:
        excluded = excluded_slot.value()
        _ = graph.id_at(excluded)

    var metric_name = dispatcher.metric_name()
    var validated = List[HnswHeapItem](capacity=len(candidates))
    for index in range(len(candidates)):
        var candidate = candidates[index].copy()
        var stored_id = graph.id_at(candidate.slot)
        if candidate.id != stored_id:
            raise Error("HNSW candidate public ID does not match graph slot")
        if not graph.is_current(candidate.slot):
            raise Error("HNSW neighbor selection requires current candidates")
        if not isfinite(candidate.distance):
            raise Error("HNSW candidate distance must be finite")
        if metric_name != "dot" and candidate.distance < 0.0:
            raise Error("L2 and cosine candidate distances cannot be negative")
        if has_excluded and candidate.slot == excluded:
            continue
        validated.append(candidate.copy())

    _sort_neighbor_candidates(validated)

    # Sort before deduplication so malformed duplicate cached distances still
    # resolve deterministically to the nearest occurrence, independent of
    # caller input order.
    var ordered = List[HnswHeapItem](capacity=len(validated))
    var seen = Dict[Int, Bool]()
    for index in range(len(validated)):
        var candidate = validated[index].copy()
        var key = Int(candidate.slot)
        if key in seen:
            continue
        seen[key] = True
        ordered.append(candidate.copy())

    var result_capacity = capacity
    if result_capacity > len(ordered):
        result_capacity = len(ordered)
    var selected = List[UInt32](capacity=result_capacity)
    if capacity == 0 or len(ordered) == 0:
        return selected^

    var pruned = List[UInt32](capacity=len(ordered))
    var evaluation_count = 0
    for candidate_index in range(len(ordered)):
        if len(selected) >= capacity:
            break
        var candidate = ordered[candidate_index].copy()
        var diverse = True
        for selected_index in range(len(selected)):
            var pair_distance = graph.distance_between(
                dispatcher, candidate.slot, selected[selected_index]
            )
            evaluation_count += 1
            if not isfinite(pair_distance):
                raise Error("HNSW neighbor-pair distance must be finite")
            if metric_name != "dot" and pair_distance < 0.0:
                raise Error("L2 and cosine pair distances cannot be negative")
            if pair_distance < candidate.distance:
                diverse = False
                break
        if diverse:
            selected.append(candidate.slot)
        elif keep_pruned_connections:
            pruned.append(candidate.slot)

    if keep_pruned_connections:
        for index in range(len(pruned)):
            if len(selected) >= capacity:
                break
            selected.append(pruned[index])

    stats.distance_evaluations += evaluation_count
    return selected^


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
