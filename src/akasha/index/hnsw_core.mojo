from akasha.compute.dispatch import (
    DISTANCE_DOT_F32,
    DISTANCE_COSINE_F32,
    DISTANCE_DOT_BF16,
    DISTANCE_COSINE_BF16,
    DISTANCE_DOT_F16,
    DISTANCE_COSINE_F16,
    DISTANCE_DOT_I8,
    DISTANCE_COSINE_I8,
)
from akasha.compute.metric import MetricDispatcher
from akasha.index.bitmap import Bitmap
from akasha.index.flat import SearchResult
from akasha.index.hnsw_heap import (
    CandidateMinHeap,
    HnswHeapItem,
    ResultMaxHeap,
)
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswBuildStats, HnswSearchStats
from akasha.index.hnsw_storage import HnswGraphAccess, HnswStorage
from std.collections import Dict
from std.math import isfinite
from std.memory import ArcPointer


struct HnswGreedyResult(Copyable, Movable):
    """The local minimum reached by one upper-layer greedy descent."""

    var slot: UInt32
    var distance: Float32

    def __init__(out self, slot: UInt32, distance: Float32):
        self.slot = slot
        self.distance = distance


trait HnswResultAdmission:
    """Internal result-admission contract shared by graph search paths."""

    def is_allow_all(self) -> Bool:
        ...

    def validate(self, slot_count: Int) raises:
        ...

    def _allows_item(self, slot: UInt32, id: Int) raises -> Bool:
        ...


struct _HnswIdOrdinalState:
    var ordinals: Dict[Int, Int]
    var ordinal_count: Int
    var construction_scanned_entries: Int
    var validation_scratch_bytes: Int
    var incremental_appends: Int

    def __init__(
        out self,
        var ordinals: Dict[Int, Int],
        ordinal_count: Int,
        construction_scanned_entries: Int,
        validation_scratch_bytes: Int,
        incremental_appends: Int,
    ):
        self.ordinals = ordinals^
        self.ordinal_count = ordinal_count
        self.construction_scanned_entries = construction_scanned_entries
        self.validation_scratch_bytes = validation_scratch_bytes
        self.incremental_appends = incremental_appends


struct HnswIdOrdinalLookup(Copyable, Movable):
    """Cheaply shared point-ID lookup, extended only under the writer lock."""

    var _state: ArcPointer[_HnswIdOrdinalState]

    def __init__(
        out self, var ordinals: Dict[Int, Int], ordinal_count: Int
    ) raises:
        if ordinal_count < 0:
            raise Error("HNSW metadata ordinal count cannot be negative")
        if len(ordinals) != ordinal_count:
            raise Error("HNSW ID lookup must cover every metadata ordinal")
        var seen = Bitmap(ordinal_count)
        var scanned = 0
        for entry in ordinals.items():
            scanned += 1
            if entry.value < 0 or entry.value >= ordinal_count:
                raise Error("HNSW metadata ordinal is outside declared domain")
            if seen.contains(entry.value):
                raise Error("HNSW metadata ordinals must be unique")
            seen.set(entry.value)
        if seen.count() != ordinal_count:
            raise Error("HNSW ID lookup must cover every metadata ordinal")
        var scratch_bytes = ((ordinal_count + 63) // 64) * 8
        self._state = ArcPointer(
            _HnswIdOrdinalState(
                ordinals^, ordinal_count, scanned, scratch_bytes, 0
            )
        )

    def entry_count(self) -> Int:
        return len(self._state[].ordinals)

    def construction_scanned_entries(self) -> Int:
        return self._state[].construction_scanned_entries

    def validation_scratch_bytes(self) -> Int:
        """Packed UInt64 bitmap payload used by one-time validation."""
        return self._state[].validation_scratch_bytes

    def incremental_append_count(self) -> Int:
        return self._state[].incremental_appends

    def append(mut self, id: Int, ordinal: Int) raises:
        """Extend the shared lookup by one newly allocated metadata slot."""
        if ordinal != self._state[].ordinal_count:
            raise Error("HNSW ID lookup append must extend the ordinal domain")
        if id in self._state[].ordinals:
            raise Error("HNSW ID lookup append ID already exists")
        self._state[].ordinals[id] = ordinal
        self._state[].ordinal_count += 1
        self._state[].incremental_appends += 1
        self._state[].validation_scratch_bytes = (
            (self._state[].ordinal_count + 63) // 64
        ) * 8

    def ordinal_for(self, id: Int) raises -> Int:
        if id in self._state[].ordinals:
            return self._state[].ordinals[id]
        return -1


struct _HnswEligibilityState:
    var allowed_ordinals: Bitmap
    var lookup: ArcPointer[_HnswIdOrdinalState]

    def __init__(
        out self,
        var allowed_ordinals: Bitmap,
        lookup: ArcPointer[_HnswIdOrdinalState],
    ):
        self.allowed_ordinals = allowed_ordinals^
        self.lookup = lookup


struct HnswEligibility(Copyable, HnswResultAdmission, Movable):
    """Metadata-bitmap result eligibility addressed strictly by public ID.

    The bitmap is query-specific and owned. The shared ID lookup is an
    ``ArcPointer`` view, so constructing repeated query adapters is O(1) in
    metadata cardinality and never clones or scans the full dictionary.
    """

    var _state: ArcPointer[_HnswEligibilityState]
    var _setup_scanned_entries: Int

    def __init__(
        out self,
        var allowed_ordinals: Bitmap,
        lookup: HnswIdOrdinalLookup,
    ):
        self._state = ArcPointer(
            _HnswEligibilityState(allowed_ordinals^, lookup._state)
        )
        # Adapter setup shares the already-validated lookup without iteration.
        self._setup_scanned_entries = 0

    def is_allow_all(self) -> Bool:
        return False

    def validate(self, slot_count: Int) raises:
        if slot_count < 0:
            raise Error("HNSW admission slot count cannot be negative")
        if (
            self._state[].allowed_ordinals.size()
            != self._state[].lookup[].ordinal_count
        ):
            raise Error("HNSW allowed bitmap does not match metadata domain")

    def setup_scanned_entries(self) -> Int:
        return self._setup_scanned_entries

    def eligible_count(self) -> Int:
        """Return the query bitmap's cached cardinality in O(1)."""
        return self._state[].allowed_ordinals.count()

    def allows(self, id: Int) raises -> Bool:
        if id not in self._state[].lookup[].ordinals:
            return False
        return self._state[].allowed_ordinals.contains(
            self._state[].lookup[].ordinals[id]
        )

    def _allows_item(self, slot: UInt32, id: Int) raises -> Bool:
        return self.allows(id)


struct HnswSearchAdmission(HnswResultAdmission, Movable):
    """Independent low-level graph-slot admission for core tests/building."""

    var _allow_all: Bool
    var _allowed_slots: List[Bool]

    def __init__(out self):
        self._allow_all = True
        self._allowed_slots = List[Bool]()

    def __init__(out self, var allowed_slots: List[Bool]):
        self._allow_all = False
        self._allowed_slots = allowed_slots^

    def is_allow_all(self) -> Bool:
        return self._allow_all

    def validate(self, slot_count: Int) raises:
        if slot_count < 0:
            raise Error("HNSW admission slot count cannot be negative")
        if not self._allow_all and len(self._allowed_slots) != slot_count:
            raise Error("HNSW admission flags do not match graph slots")

    def allows(self, slot: UInt32) -> Bool:
        if self._allow_all:
            return True
        return self._allowed_slots[Int(slot)]

    def _allows_item(self, slot: UInt32, id: Int) raises -> Bool:
        return self.allows(slot)


struct HnswValidationStats(Copyable, Movable):
    """Actual packed cells inspected by a bidirectional-link audit."""

    var owned_level_cells: Int
    var directed_edges: Int
    var auxiliary_reserved_bytes: Int

    def __init__(out self):
        self.auxiliary_reserved_bytes = 0
        self.owned_level_cells = 0
        self.directed_edges = 0


struct HnswWideningOutcome(Movable):
    """One shared owned-or-mapped filtered widening execution."""

    var results: List[SearchResult]
    var stats: HnswSearchStats
    var query_preparations: Int
    var upper_descents: Int

    def __init__(
        out self,
        var results: List[SearchResult],
        var stats: HnswSearchStats,
        query_preparations: Int,
        upper_descents: Int,
    ):
        self.results = results^
        self.stats = stats^
        self.query_preparations = query_preparations
        self.upper_descents = upper_descents

    def take_results(mut self) -> List[SearchResult]:
        var result = self.results^
        self.results = List[SearchResult]()
        return result^

    def take_stats(mut self) -> HnswSearchStats:
        var result = self.stats^
        self.stats = HnswSearchStats()
        return result^


def _search_item_better(lhs: HnswHeapItem, rhs: HnswHeapItem) -> Bool:
    """Deterministic strict ordering by distance, public ID, then slot."""
    if lhs.distance != rhs.distance:
        return lhs.distance < rhs.distance
    if lhs.id != rhs.id:
        return lhs.id < rhs.id
    return lhs.slot < rhs.slot


def _select_neighbors_heuristic[
    backend_tag: Int = -1
](
    graph: HnswStorage,
    dispatcher: MetricDispatcher,
    candidates: List[HnswHeapItem],
    excluded_slot: Optional[UInt32],
    capacity: Int,
    keep_pruned_connections: Bool,
    require_current_candidates: Bool,
    mut stats: HnswBuildStats,
) raises -> List[UInt32]:
    """Select deterministic, geometrically diverse graph slots.

    Candidate distances are caller-cached canonical query-to-candidate
    distances and are never recomputed here. Inputs are first validated and
    ordered by ``(distance, public ID, slot)``. Duplicate slots and the
    optional query/self slot are then removed. Public construction calls set
    ``require_current_candidates`` so historical candidates cannot silently
    become new links. Internal pruning may clear it to retain structurally
    valid historical adjacency as navigation bridges.

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
    if not dispatcher.matches_storage_identity(
        graph.metric_kind, graph.scalar_kind, graph.dimension
    ):
        raise Error("metric dispatcher identity does not match HNSW graph")

    var has_excluded = Bool(excluded_slot)
    var excluded = UInt32(0)
    if has_excluded:
        excluded = excluded_slot.value()
        _ = graph.id_at(excluded)

    # Direct core tests retain a runtime dispatcher seam. Public index paths
    # pass a backend tag, so their metric validation is compile-time only.
    var is_dot = False
    var is_cosine = False
    comptime if backend_tag < 0:
        var metric_name = dispatcher.metric_name()
        is_dot = metric_name == "dot"
        is_cosine = metric_name == "cosine"
    var ordered_heap = CandidateMinHeap()
    ordered_heap.reserve(len(candidates))
    for index in range(len(candidates)):
        var candidate = candidates[index].copy()
        var stored_id = graph.id_at(candidate.slot)
        if candidate.id != stored_id:
            raise Error("HNSW candidate public ID does not match graph slot")
        if require_current_candidates and not graph.is_current(candidate.slot):
            raise Error("HNSW neighbor selection requires current candidates")
        if not isfinite(candidate.distance):
            raise Error("HNSW candidate distance must be finite")
        comptime if backend_tag < 0:
            if not is_dot and candidate.distance < 0.0:
                raise Error(
                    "L2 and cosine candidate distances cannot be negative"
                )
            if is_cosine and candidate.distance > 2.0:
                raise Error("cosine candidate distance cannot exceed two")
        else:
            comptime if backend_tag not in (
                DISTANCE_DOT_F32,
                DISTANCE_DOT_BF16,
                DISTANCE_DOT_F16,
                DISTANCE_DOT_I8,
            ):
                if candidate.distance < 0.0:
                    raise Error(
                        "L2 and cosine candidate distances cannot be negative"
                    )
            comptime if backend_tag in (
                DISTANCE_COSINE_F32,
                DISTANCE_COSINE_BF16,
                DISTANCE_COSINE_F16,
                DISTANCE_COSINE_I8,
            ):
                if candidate.distance > 2.0:
                    raise Error("cosine candidate distance cannot exceed two")
        if has_excluded and candidate.slot == excluded:
            continue
        ordered_heap.push(candidate)

    # Drain the total-key min-heap before deduplication, giving O(n log n)
    # deterministic ordering and ensuring malformed duplicate cached
    # distances still resolve to the nearest occurrence independent of input
    # order.
    var ordered = List[HnswHeapItem](capacity=len(candidates))
    var seen = Dict[Int, Bool]()
    while not ordered_heap.is_empty():
        var candidate = ordered_heap.pop()
        var key = Int(candidate.slot)
        if key in seen:
            continue
        seen[key] = True
        ordered.append(candidate^)

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
            var pair_distance: Float32
            comptime if backend_tag < 0:
                pair_distance = graph.distance_between(
                    dispatcher, candidate.slot, selected[selected_index]
                )
            else:
                pair_distance = graph._distance_between_backend[backend_tag](
                    dispatcher, candidate.slot, selected[selected_index]
                )
            evaluation_count += 1
            if not isfinite(pair_distance):
                raise Error("HNSW neighbor-pair distance must be finite")
            comptime if backend_tag < 0:
                if not is_dot and pair_distance < 0.0:
                    raise Error(
                        "L2 and cosine pair distances cannot be negative"
                    )
                if is_cosine and pair_distance > 2.0:
                    raise Error(
                        "cosine neighbor-pair distance cannot exceed two"
                    )
            else:
                comptime if backend_tag not in (
                    DISTANCE_DOT_F32,
                    DISTANCE_DOT_BF16,
                    DISTANCE_DOT_F16,
                    DISTANCE_DOT_I8,
                ):
                    if pair_distance < 0.0:
                        raise Error(
                            "L2 and cosine pair distances cannot be negative"
                        )
                comptime if backend_tag in (
                    DISTANCE_COSINE_F32,
                    DISTANCE_COSINE_BF16,
                    DISTANCE_COSINE_F16,
                    DISTANCE_COSINE_I8,
                ):
                    if pair_distance > 2.0:
                        raise Error(
                            "cosine neighbor-pair distance cannot exceed two"
                        )
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


def select_neighbors_heuristic[
    backend_tag: Int = -1
](
    graph: HnswStorage,
    dispatcher: MetricDispatcher,
    candidates: List[HnswHeapItem],
    excluded_slot: Optional[UInt32],
    capacity: Int,
    keep_pruned_connections: Bool,
    mut stats: HnswBuildStats,
) raises -> List[UInt32]:
    """Select current construction candidates using the HNSW heuristic."""
    return _select_neighbors_heuristic[backend_tag](
        graph,
        dispatcher,
        candidates,
        excluded_slot,
        capacity,
        keep_pruned_connections,
        True,
        stats,
    )


def _slot_in_list(values: List[UInt32], slot: UInt32) -> Bool:
    for value in values:
        if value == slot:
            return True
    return False


def _adjacency_with_candidate[
    backend_tag: Int = -1
](
    graph: HnswStorage,
    dispatcher: MetricDispatcher,
    center: UInt32,
    candidate: UInt32,
    level: Int,
    mut stats: HnswBuildStats,
) raises -> List[UInt32]:
    """Return the bounded adjacency obtained by considering one new edge."""
    var count = graph.neighbor_count(center, level)
    var values = List[UInt32](capacity=count + 1)
    for index in range(count):
        values.append(graph.neighbor_at(center, level, index))
    if not _slot_in_list(values, candidate):
        values.append(candidate)

    var capacity = graph.level_capacity(center, level)
    if len(values) <= capacity:
        return values^

    var candidates = List[HnswHeapItem](capacity=len(values))
    for value in values:
        var distance: Float32
        comptime if backend_tag < 0:
            distance = graph.distance_between(dispatcher, center, value)
        else:
            distance = graph._distance_between_backend[backend_tag](
                dispatcher, center, value
            )
        candidates.append(HnswHeapItem(value, graph.id_at(value), distance))
        stats.distance_evaluations += 1
    var no_exclusion = Optional[UInt32]()
    # Existing adjacency may intentionally retain inactive historical nodes as
    # navigation bridges. The public construction selector remains strict;
    # this internal pruning path alone accepts those structurally valid slots.
    return _select_neighbors_heuristic[backend_tag](
        graph,
        dispatcher,
        candidates,
        no_exclusion,
        capacity,
        True,
        False,
        stats,
    )


def _copy_adjacency(
    graph: HnswStorage, center: UInt32, level: Int
) raises -> List[UInt32]:
    var count = graph.neighbor_count(center, level)
    var values = List[UInt32](capacity=count)
    for index in range(count):
        values.append(graph.neighbor_at(center, level, index))
    return values^


def _removed_neighbors(
    graph: HnswStorage,
    center: UInt32,
    level: Int,
    retained: List[UInt32],
) raises -> List[UInt32]:
    """Snapshot removed edges before packed adjacency is overwritten."""
    var removed = List[UInt32]()
    var count = graph.neighbor_count(center, level)
    for index in range(count):
        var neighbor = graph.neighbor_at(center, level, index)
        if not _slot_in_list(retained, neighbor):
            removed.append(neighbor)
    return removed^


def _validate_link_level(graph: HnswStorage, slot: UInt32, level: Int) raises:
    if level < 0 or level > graph.level(slot):
        raise Error("HNSW node does not own touched graph level")
    var count = graph.neighbor_count(slot, level)
    if count > graph.level_capacity(slot, level):
        raise Error("HNSW touched adjacency exceeds level capacity")
    for edge_index in range(count):
        var neighbor = graph.neighbor_at(slot, level, edge_index)
        if graph.level(neighbor) < level:
            raise Error("HNSW edge target does not own graph level")
        if not graph.contains_neighbor(neighbor, level, slot):
            raise Error("HNSW graph contains an asymmetric edge")


def _audit_bidirectional_links_with_stats[
    GraphType: HnswGraphAccess
](graph: GraphType, mut stats: HnswValidationStats) raises:
    """Audit links after the concrete graph proved its local structure."""
    graph.validate_search_ready()

    # Give every actually owned (slot, level) cell a dense UInt32 ordinal.
    # This avoids scanning every slot for every level when one sparse node has
    # a hostile high level, while retaining compact exact UInt64 edge keys.
    var level_groups = Dict[UInt64, UInt32]()
    var owned_level_cells = 0
    for index in range(graph.slot_count()):
        var slot = UInt32(index)
        for level in range(graph.level(slot) + 1):
            if UInt64(owned_level_cells) >= UInt64(UInt32.MAX):
                raise Error(
                    "HNSW owned level count exceeds validation address space"
                )
            var group_key = (UInt64(level) << UInt64(32)) | UInt64(slot)
            level_groups[group_key] = UInt32(owned_level_cells)
            owned_level_cells += 1

    var edges = List[UInt64]()
    var required_reverse_edges = List[UInt64]()
    var directed_edges = 0
    for index in range(graph.slot_count()):
        var slot = UInt32(index)
        for level in range(graph.level(slot) + 1):
            var count = graph.neighbor_count(slot, level)
            var capacity = graph.graph_m()
            if level == 0:
                capacity = graph.graph_m0()
            if count > capacity:
                raise Error("HNSW touched adjacency exceeds level capacity")
            var source_group_key = (UInt64(level) << UInt64(32)) | UInt64(slot)
            var source_group = level_groups[source_group_key]
            for edge_index in range(count):
                var neighbor = graph.neighbor_at(slot, level, edge_index)
                if graph.level(neighbor) < level:
                    raise Error("HNSW edge target does not own graph level")
                var edge_key = (UInt64(source_group) << UInt64(32)) | UInt64(
                    neighbor
                )
                edges.append(edge_key)
                var target_group_key = (UInt64(level) << UInt64(32)) | UInt64(
                    neighbor
                )
                var target_group = level_groups[target_group_key]
                required_reverse_edges.append(
                    (UInt64(target_group) << UInt64(32)) | UInt64(slot)
                )
                directed_edges += 1

    sort(Span(edges))
    sort(Span(required_reverse_edges))
    for index in range(len(edges)):
        if edges[index] != required_reverse_edges[index]:
            raise Error("HNSW graph contains an asymmetric edge")

    stats.owned_level_cells = owned_level_cells
    stats.directed_edges = directed_edges
    stats.auxiliary_reserved_bytes = (
        edges.capacity() + required_reverse_edges.capacity()
    ) * 8


def validate_bidirectional_links_with_stats[
    GraphType: HnswGraphAccess
](graph: GraphType, mut stats: HnswValidationStats) raises:
    """Validate local structure, then audit all reciprocal graph links."""
    graph.validate_structure()
    _audit_bidirectional_links_with_stats(graph, stats)


def _audit_bidirectional_links[
    GraphType: HnswGraphAccess
](graph: GraphType) raises:
    """Internal reciprocal-link audit for a graph already locally checked."""
    var stats = HnswValidationStats()
    _audit_bidirectional_links_with_stats(graph, stats)


def validate_bidirectional_links[
    GraphType: HnswGraphAccess
](graph: GraphType) raises:
    """Audit packed structure, level ownership, and edge symmetry."""
    var stats = HnswValidationStats()
    validate_bidirectional_links_with_stats(graph, stats)


def connect_bidirectional[
    backend_tag: Int = -1
](
    mut graph: HnswStorage,
    dispatcher: MetricDispatcher,
    endpoint: UInt32,
    level: Int,
    selected_neighbors: List[UInt32],
    mut stats: HnswBuildStats,
) raises:
    """Connect selected slots while preserving bounded symmetric adjacency.

    Every overflowing endpoint is re-selected around its own vector. Removed
    edges are snapshotted before replacing the packed list, then removed from
    their reverse endpoints without recursive pruning. Caller errors are fully
    validated before mutation. Any later failure quarantines the graph so a
    collection can route around the partially updated derived index.
    """
    if not graph.is_valid():
        raise Error("cannot mutate an invalid HNSW graph")
    dispatcher.require_supported_backend()
    if dispatcher.dimension() != graph.dimension:
        raise Error("metric dispatcher dimension does not match HNSW graph")
    _ = graph.level_capacity(endpoint, level)
    if not graph.is_current(endpoint):
        raise Error("HNSW link endpoint must be current")

    # Validate and deduplicate the complete proposal set before any mutation.
    var proposals = List[UInt32](capacity=len(selected_neighbors))
    var seen = Dict[Int, Bool]()
    for neighbor in selected_neighbors:
        _ = graph.id_at(neighbor)
        if neighbor == endpoint:
            raise Error("HNSW self edges are not allowed")
        if graph.level(neighbor) < level:
            raise Error("HNSW edge target does not own graph level")
        if not graph.is_current(neighbor):
            raise Error("HNSW link neighbor must be current")
        var key = Int(neighbor)
        if key not in seen:
            seen[key] = True
            proposals.append(neighbor)

    var local_stats = HnswBuildStats()
    var directed_edge_delta = 0
    try:
        for neighbor in proposals:
            var endpoint_original = _copy_adjacency(graph, endpoint, level)
            var neighbor_original = _copy_adjacency(graph, neighbor, level)
            var endpoint_final = _adjacency_with_candidate[backend_tag](
                graph,
                dispatcher,
                endpoint,
                neighbor,
                level,
                local_stats,
            )
            var neighbor_final = _adjacency_with_candidate[backend_tag](
                graph,
                dispatcher,
                neighbor,
                endpoint,
                level,
                local_stats,
            )

            # An edge is visible only if both endpoint-centered selections keep
            # it. This prevents either pruning decision from creating a one-way
            # adjacency.
            var keep_edge = _slot_in_list(endpoint_final, neighbor)
            keep_edge = keep_edge and _slot_in_list(neighbor_final, endpoint)
            if not keep_edge:
                # A proposal rejected by either endpoint never happened. Keep
                # both prior bounded lists instead of losing unrelated edges
                # selected out only while the rejected edge was considered.
                endpoint_final = endpoint_original^
                neighbor_final = neighbor_original^

            var removed_from_endpoint = _removed_neighbors(
                graph, endpoint, level, endpoint_final
            )
            var removed_from_neighbor = _removed_neighbors(
                graph, neighbor, level, neighbor_final
            )

            var endpoint_before = graph.neighbor_count(endpoint, level)
            graph.set_neighbors(endpoint, level, endpoint_final^)
            directed_edge_delta += (
                graph.neighbor_count(endpoint, level) - endpoint_before
            )
            var neighbor_before = graph.neighbor_count(neighbor, level)
            graph.set_neighbors(neighbor, level, neighbor_final^)
            directed_edge_delta += (
                graph.neighbor_count(neighbor, level) - neighbor_before
            )

            for removed in removed_from_endpoint:
                if graph.remove_neighbor(removed, level, endpoint):
                    directed_edge_delta -= 1
            for removed in removed_from_neighbor:
                if graph.remove_neighbor(removed, level, neighbor):
                    directed_edge_delta -= 1

            _validate_link_level(graph, endpoint, level)
            _validate_link_level(graph, neighbor, level)
            for removed in removed_from_endpoint:
                _validate_link_level(graph, removed, level)
            for removed in removed_from_neighbor:
                _validate_link_level(graph, removed, level)
    except error:
        # All public validation finished before entering this transaction.
        # Any remaining failure means internal graph state or link processing
        # is unsafe, even when it happened before the first packed write.
        graph.mark_invalid()
        raise Error(String(error))

    stats.distance_evaluations += local_stats.distance_evaluations
    stats.directed_edges += directed_edge_delta


def _validate_search_boundary[
    GraphType: HnswGraphAccess
](
    graph: GraphType,
    dispatcher: MetricDispatcher,
    query: List[Float32],
    entry: UInt32,
    level: Int,
) raises:
    """Validate all caller-owned state before scratch or stats are mutated."""
    graph.validate_search_ready()
    dispatcher.require_supported_backend()
    if graph.slot_count() <= 0:
        raise Error("cannot search an empty HNSW graph")
    if (
        graph.graph_dimension() <= 0
        or graph.graph_m() <= 0
        or graph.graph_m0() <= 0
    ):
        raise Error("HNSW graph configuration is invalid")
    if dispatcher.dimension() != graph.graph_dimension():
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


def greedy_descent[
    GraphType: HnswGraphAccess, backend_tag: Int = -1
](
    graph: GraphType,
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
    var current_distance: Float32
    comptime if backend_tag < 0:
        current_distance = graph.distance_to_slot(dispatcher, query, entry)
    else:
        current_distance = graph._distance_to_slot_backend[backend_tag](
            dispatcher, query, entry
        )
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
                comptime if backend_tag < 0:
                    neighbor_distance = graph.distance_to_slot(
                        dispatcher, query, neighbor
                    )
                else:
                    neighbor_distance = graph._distance_to_slot_backend[
                        backend_tag
                    ](dispatcher, query, neighbor)
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


def _consider_result_admission[
    GraphType: HnswGraphAccess, AdmissionType: HnswResultAdmission
](
    graph: GraphType,
    admission: AdmissionType,
    item: HnswHeapItem,
    ef: Int,
    mut results: ResultMaxHeap,
    mut stats: HnswSearchStats,
) raises:
    if not graph.is_current(item.slot):
        stats.inactive_rejections += 1
        return
    if not admission._allows_item(item.slot, item.id):
        stats.filtered_rejections += 1
        return
    results.offer(item, ef)


def search_layer[
    GraphType: HnswGraphAccess,
    AdmissionType: HnswResultAdmission,
    backend_tag: Int = -1,
](
    graph: GraphType,
    dispatcher: MetricDispatcher,
    query: List[Float32],
    entry: UInt32,
    level: Int,
    k: Int,
    ef: Int,
    admission: AdmissionType,
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

    var is_filtered = not admission.is_allow_all()
    scratch.begin(graph.slot_count(), ef, prepare_filtered=is_filtered)
    _ = scratch.visit(entry)
    var entry_distance: Float32
    comptime if backend_tag < 0:
        entry_distance = graph.distance_to_slot(dispatcher, query, entry)
    else:
        entry_distance = graph._distance_to_slot_backend[backend_tag](
            dispatcher, query, entry
        )
    var entry_item = HnswHeapItem(entry, graph.id_at(entry), entry_distance)
    stats.base_visited += 1
    stats.distance_evaluations += 1
    scratch.candidates.push(entry_item)
    if is_filtered:
        # The traversal radius is retained independently of eligibility.
        scratch.results.offer(entry_item, ef)
        _consider_result_admission(
            graph, admission, entry_item, ef, scratch.filtered_results, stats
        )
    else:
        _consider_result_admission(
            graph, admission, entry_item, ef, scratch.results, stats
        )

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

            var distance: Float32
            comptime if backend_tag < 0:
                distance = graph.distance_to_slot(dispatcher, query, neighbor)
            else:
                distance = graph._distance_to_slot_backend[backend_tag](
                    dispatcher, query, neighbor
                )
            var item = HnswHeapItem(neighbor, graph.id_at(neighbor), distance)
            stats.base_visited += 1
            stats.distance_evaluations += 1

            if is_filtered:
                scratch.results.offer(item, ef)
                _consider_result_admission(
                    graph,
                    admission,
                    item,
                    ef,
                    scratch.filtered_results,
                    stats,
                )
            else:
                _consider_result_admission(
                    graph, admission, item, ef, scratch.results, stats
                )

            if (
                len(scratch.results) < ef
                or item.distance <= scratch.results.peek_worst().distance
            ):
                scratch.candidates.push(item)

    var best: List[HnswHeapItem]
    if is_filtered:
        best = scratch.filtered_results.take_sorted_best()
    else:
        best = scratch.results.take_sorted_best()
    while len(best) > k:
        _ = best.pop()
    stats.retained_candidates = len(best)
    return best^


def _next_widened_ef(current_ef: Int, max_ef: Int) raises -> Int:
    """Double a positive ef and saturate without integer overflow."""
    if current_ef <= 0 or max_ef <= 0 or current_ef > max_ef:
        raise Error("HNSW widening ef range is invalid")
    if current_ef == max_ef or current_ef > max_ef // 2:
        return max_ef
    return current_ef * 2


def search_allowed_with_widening_core[
    GraphType: HnswGraphAccess,
    AdmissionType: HnswResultAdmission,
    backend_tag: Int = -1,
](
    graph: GraphType,
    dispatcher: MetricDispatcher,
    query: List[Float32],
    k: Int,
    initial_ef: Int,
    max_ef: Int,
    eligible_count: Int,
    return_search_breadth: Bool,
    exact_fallback: Bool,
    entry_slot: Optional[UInt32],
    entry_level: Int,
    storage_name: String,
    allowed: AdmissionType,
    mut scratch: HnswSearchScratch,
) raises -> HnswWideningOutcome:
    """Validate one raw query, prepare it once, then run the shared core."""
    graph.validate_search_ready()
    dispatcher.require_supported_backend()
    if dispatcher.dimension() != graph.graph_dimension():
        raise Error("metric dispatcher dimension does not match HNSW graph")
    if k <= 0:
        raise Error("HNSW search k must be positive")
    if initial_ef <= 0 or max_ef <= 0 or initial_ef > max_ef:
        raise Error("HNSW widening ef range is invalid")
    if eligible_count < 0:
        raise Error("HNSW eligible count cannot be negative")
    allowed.validate(graph.slot_count())
    var prepared = dispatcher.prepare_query(query)
    var outcome = search_prepared_allowed_with_widening_core[
        backend_tag=backend_tag
    ](
        graph,
        dispatcher,
        prepared,
        k,
        initial_ef,
        max_ef,
        eligible_count,
        return_search_breadth,
        exact_fallback,
        entry_slot,
        entry_level,
        storage_name,
        allowed,
        scratch,
    )
    outcome.query_preparations = 1
    return outcome^


def search_prepared_allowed_with_widening_core[
    GraphType: HnswGraphAccess,
    AdmissionType: HnswResultAdmission,
    backend_tag: Int = -1,
](
    graph: GraphType,
    dispatcher: MetricDispatcher,
    prepared: List[Float32],
    k: Int,
    initial_ef: Int,
    max_ef: Int,
    eligible_count: Int,
    return_search_breadth: Bool,
    exact_fallback: Bool,
    entry_slot: Optional[UInt32],
    entry_level: Int,
    storage_name: String,
    allowed: AdmissionType,
    mut scratch: HnswSearchScratch,
) raises -> HnswWideningOutcome:
    """Consume one prepared query and reuse it through every widening round.

    Normal index queries return ``k`` results and may exact-complete one graph.
    Segmented callers instead request the final ``ef`` candidate breadth and
    defer exact fallback until all graph sources have been merged. Those
    callers may share this same prepared query across multiple graph sources.
    """
    graph.validate_search_ready()
    dispatcher.require_supported_backend()
    if dispatcher.dimension() != graph.graph_dimension():
        raise Error("metric dispatcher dimension does not match HNSW graph")
    if k <= 0:
        raise Error("HNSW search k must be positive")
    if initial_ef <= 0 or max_ef <= 0 or initial_ef > max_ef:
        raise Error("HNSW widening ef range is invalid")
    if eligible_count < 0:
        raise Error("HNSW eligible count cannot be negative")
    allowed.validate(graph.slot_count())
    dispatcher.validate_prepared_vector(prepared)

    var stats = HnswSearchStats()
    stats.requested_ef = initial_ef
    stats.effective_ef = initial_ef
    stats.backend_name = dispatcher.backend_name()
    stats.metric_name = dispatcher.metric_name()
    stats.scalar_name = dispatcher.scalar_name()
    stats.storage_name = storage_name

    var target_count = k
    if target_count > eligible_count:
        target_count = eligible_count
    if target_count > graph.slot_count():
        target_count = graph.slot_count()
    var effective_ceiling = max_ef
    if effective_ceiling > graph.slot_count():
        effective_ceiling = graph.slot_count()
    if target_count == 0 or not Bool(entry_slot):
        stats.requested_ef = 0
        stats.effective_ef = 0
        return HnswWideningOutcome(List[SearchResult](), stats^, 0, 0)

    var current_ef = initial_ef
    if current_ef < target_count:
        current_ef = target_count
    if current_ef > effective_ceiling:
        current_ef = effective_ceiling
    if current_ef < target_count:
        raise Error("HNSW result demand exceeds traversable graph slots")

    var current = entry_slot.value()
    var upper_descents = 0
    for level in range(entry_level, 0, -1):
        current = greedy_descent[backend_tag=backend_tag](
            graph, dispatcher, prepared, current, level, stats
        ).slot
        upper_descents += 1
    var upper_stats = stats^
    var widening_rounds = 0
    var results: List[SearchResult]
    while True:
        stats = HnswSearchStats()
        stats.requested_ef = current_ef
        stats.effective_ef = current_ef
        stats.upper_visited = upper_stats.upper_visited
        stats.distance_evaluations = upper_stats.distance_evaluations
        stats.backend_name = upper_stats.backend_name.copy()
        stats.metric_name = upper_stats.metric_name.copy()
        stats.scalar_name = upper_stats.scalar_name.copy()
        stats.storage_name = upper_stats.storage_name.copy()
        var result_limit = target_count
        if return_search_breadth:
            result_limit = current_ef
        var candidates = search_layer[backend_tag=backend_tag](
            graph,
            dispatcher,
            prepared,
            current,
            0,
            result_limit,
            current_ef,
            allowed,
            scratch,
            stats,
        )
        results = List[SearchResult](capacity=len(candidates))
        for candidate in candidates:
            results.append(
                SearchResult(
                    candidate.id,
                    dispatcher.public_score(candidate.distance),
                )
            )
        if len(results) >= target_count or current_ef >= effective_ceiling:
            break
        var widened = _next_widened_ef(current_ef, effective_ceiling)
        if widened == current_ef:
            break
        current_ef = widened
        widening_rounds += 1

    stats.widening_rounds = widening_rounds
    if len(results) < target_count and exact_fallback:
        var retained = ResultMaxHeap()
        retained.reserve(target_count)
        for slot_index in range(graph.slot_count()):
            var slot = UInt32(slot_index)
            var id = graph.id_at(slot)
            if not graph.is_current(slot) or not allowed._allows_item(slot, id):
                continue
            var distance: Float32
            comptime if backend_tag < 0:
                distance = graph.distance_to_slot(dispatcher, prepared, slot)
            else:
                distance = graph._distance_to_slot_backend[backend_tag](
                    dispatcher, prepared, slot
                )
            retained.offer(HnswHeapItem(slot, id, distance), target_count)
        var exact = retained.take_sorted_best()
        results = List[SearchResult](capacity=len(exact))
        for candidate in exact:
            results.append(
                SearchResult(
                    candidate.id,
                    dispatcher.public_score(candidate.distance),
                )
            )
        stats.fallback_reason = "filtered_ann_exhausted"
    return HnswWideningOutcome(results^, stats^, 0, upper_descents)
