from akasha.index.hnsw_query_scorer import HnswQueryScorer, MetricPointScorer
from akasha.query.control import QueryControl
from akasha.index.hnsw_admission import HnswResultAdmission
from akasha.index.hnsw_entries import HnswEntryPoints
from akasha.index.hnsw_search import search_entry, search_level
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
    valid historical adjacency without making historical slots searchable.

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
        ordered.append(candidate)

    var result_capacity = capacity
    if result_capacity > len(ordered):
        result_capacity = len(ordered)
    var selected = List[UInt32](capacity=result_capacity)
    if capacity == 0 or len(ordered) == 0:
        return selected^

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
    mut stats: HnswBuildStats,
) raises -> List[UInt32]:
    """Select current construction candidates using the HNSW heuristic."""
    return _select_neighbors_heuristic[backend_tag](
        graph,
        dispatcher,
        candidates,
        excluded_slot,
        capacity,
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
    # Existing adjacency may retain inactive historical slots in durable state.
    # The public construction selector remains strict;
    # this internal pruning path alone accepts those structurally valid slots.
    return _select_neighbors_heuristic[backend_tag](
        graph,
        dispatcher,
        candidates,
        no_exclusion,
        capacity,
        False,
        stats,
    )


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
            var edge_range = graph.neighbor_range(slot, level)
            var count = edge_range[1]
            var capacity = graph.graph_m()
            if level == 0:
                capacity = graph.graph_m0()
            if count > capacity:
                raise Error("HNSW touched adjacency exceeds level capacity")
            var source_group_key = (UInt64(level) << UInt64(32)) | UInt64(slot)
            var source_group = level_groups[source_group_key]
            for edge_index in range(count):
                var neighbor = graph.neighbor_at_offset(edge_range[0] + edge_index)
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


def connect_with_heuristic[
    backend_tag: Int = -1
](
    mut graph: HnswStorage,
    dispatcher: MetricDispatcher,
    endpoint: UInt32,
    level: Int,
    selected_neighbors: List[UInt32],
    mut stats: HnswBuildStats,
) raises:
    """Publish selected outgoing links and prune each backlink independently.

    Port of Qdrant GraphLayersBuilder::link_with_heuristic and the semantics
    of LinksContainer::connect_with_heuristic_simple, commit 21db2f3ff95d.
    Apache-2.0; see benchmarks/licenses/qdrant-APACHE-2.0.txt. A rejected or
    evicted backlink must not erase the separately selected opposite edge.
    """
    if not graph.is_valid():
        raise Error("cannot mutate an invalid HNSW graph")
    dispatcher.require_supported_backend()
    if not dispatcher.matches_storage_identity(
        graph.metric_kind, graph.scalar_kind, graph.dimension
    ):
        raise Error("metric dispatcher identity does not match HNSW graph")
    var capacity = graph.level_capacity(endpoint, level)
    if not graph.is_current(endpoint):
        raise Error("HNSW link endpoint must be current")
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
        if Int(neighbor) not in seen:
            seen[Int(neighbor)] = True
            proposals.append(neighbor)
    if len(proposals) > capacity:
        raise Error("HNSW selected links exceed level capacity")

    var local_stats = HnswBuildStats()
    var directed_edge_delta = 0
    try:
        var before = graph.neighbor_count(endpoint, level)
        graph.set_neighbors(endpoint, level, proposals)
        directed_edge_delta += len(proposals) - before
        for neighbor in proposals:
            before = graph.neighbor_count(neighbor, level)
            var links = _adjacency_with_candidate[backend_tag](
                graph, dispatcher, neighbor, endpoint, level, local_stats
            )
            graph.set_neighbors(neighbor, level, links)
            directed_edge_delta += len(links) - before
    except error:
        graph.mark_invalid()
        raise Error(String(error))
    stats.distance_evaluations += local_stats.distance_evaluations
    stats.directed_edges += directed_edge_delta


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
    entries: HnswEntryPoints,
    storage_name: String,
    allowed: AdmissionType,
    mut scratch: HnswSearchScratch,
    control: Optional[QueryControl] = None,
) raises -> HnswWideningOutcome:
    """Validate one raw query, prepare it once, then run the shared core."""
    if control:
        control.value().checkpoint(0)
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
    var outcome = search_scored_allowed_with_widening_core[
        backend_tag=backend_tag
    ](
        graph,
        MetricPointScorer(dispatcher, prepared^),
        k,
        initial_ef,
        max_ef,
        eligible_count,
        return_search_breadth,
        exact_fallback,
        entries,
        storage_name,
        allowed,
        scratch,
        control=control,
    )
    outcome.query_preparations = 1
    return outcome^


def search_scored_allowed_with_widening_core[
    GraphType: HnswGraphAccess,
    AdmissionType: HnswResultAdmission,
    ScorerType: HnswQueryScorer,
    backend_tag: Int = -1,
](
    graph: GraphType,
    scorer: ScorerType,
    k: Int,
    initial_ef: Int,
    max_ef: Int,
    eligible_count: Int,
    return_search_breadth: Bool,
    exact_fallback: Bool,
    entries: HnswEntryPoints,
    storage_name: String,
    allowed: AdmissionType,
    mut scratch: HnswSearchScratch,
    control: Optional[QueryControl] = None,
) raises -> HnswWideningOutcome:
    """Consume one prepared query and reuse it through every widening round.

    Normal index queries return ``k`` results and may exact-complete one graph.
    Segmented callers instead request the final ``ef`` candidate breadth and
    defer exact fallback until all graph sources have been merged. Those
    callers may share this same prepared query across multiple graph sources.
    """
    if control:
        control.value().checkpoint(0)
    graph.validate_search_ready()
    scorer.validate(graph)
    if k <= 0:
        raise Error("HNSW search k must be positive")
    if initial_ef <= 0 or max_ef <= 0 or initial_ef > max_ef:
        raise Error("HNSW widening ef range is invalid")
    if eligible_count < 0:
        raise Error("HNSW eligible count cannot be negative")
    allowed.validate(graph.slot_count())

    var stats = HnswSearchStats()
    stats.requested_ef = initial_ef
    stats.effective_ef = initial_ef
    stats.backend_name = scorer.backend_name()
    stats.metric_name = scorer.metric_name()
    stats.scalar_name = scorer.scalar_name()
    stats.storage_name = storage_name

    var target_count = min(k, min(eligible_count, graph.slot_count()))
    var effective_ceiling = min(max_ef, graph.slot_count())
    if target_count == 0:
        stats.requested_ef = 0
        stats.effective_ef = 0
        return HnswWideningOutcome(List[SearchResult](), stats^, 0, 0)
    var current_ef = min(max(initial_ef, target_count), effective_ceiling)
    if current_ef < target_count:
        raise Error("HNSW result demand exceeds traversable graph slots")
    var selected_entry = entries.get_entry(graph, allowed)
    var results = List[SearchResult]()
    var upper_descents = 0
    var widening_rounds = 0
    if selected_entry:
        var current = selected_entry.value()
        upper_descents = current.level
        var entry = search_entry[backend_tag=backend_tag, collect_seeds=True](
            graph, scorer, current.slot, upper_descents, 0, allowed, scratch, stats,
            control=control, seed_ef=current_ef,
        )
        var seeds = scratch.results.take_unordered()
        var upper_stats = stats^
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
            var limit = current_ef if return_search_breadth else target_count
            var candidates = search_level[backend_tag=backend_tag](
                graph, scorer, entry, 0, current_ef, allowed, scratch, stats,
                control=control, seeds=seeds,
            )
            results = List[SearchResult](capacity=min(limit, len(candidates)))
            for ordinal in range(min(limit, len(candidates))):
                var candidate = candidates[ordinal]
                results.append(SearchResult(candidate.id, scorer.public_score(candidate.distance)))
            stats.retained_candidates = len(results)
            if len(results) >= target_count or current_ef >= effective_ceiling:
                break
            current_ef = _next_widened_ef(current_ef, effective_ceiling)
            widening_rounds += 1
    else:
        stats.effective_ef = 0
    stats.widening_rounds = widening_rounds
    if len(results) < target_count and exact_fallback:
        var retained = ResultMaxHeap()
        retained.reserve(target_count)
        for slot_index in range(graph.slot_count()):
            if control:
                control.value().checkpoint(slot_index)
            var slot = UInt32(slot_index)
            var id = graph.id_at(slot)
            if not graph.is_current(slot) or not allowed._allows_item(slot, id):
                continue
            var distance = scorer.distance[backend_tag](graph, slot, control)
            retained.offer(HnswHeapItem(slot, id, distance), target_count)
        var exact = retained.take_sorted_best()
        results = List[SearchResult](capacity=len(exact))
        for candidate in exact:
            results.append(
                SearchResult(
                    candidate.id,
                    scorer.public_score(candidate.distance),
                )
            )
        stats.fallback_reason = "filtered_ann_exhausted"
    return HnswWideningOutcome(results^, stats^, 0, upper_descents)
