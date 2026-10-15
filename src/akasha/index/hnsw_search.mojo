"""Qdrant's ordinary filtered HNSW search, before performance adaptations.

Adapted from Qdrant (Apache-2.0), commit
21db2f3ff95d50de3a2b88a741312c056fd1762d, graph_layers.rs,
entry_points.rs, point_scorer.rs and search_context.rs. See benchmarks/mojo/
qdrant_search_reference.md for provenance and benchmarks/licenses/
qdrant-APACHE-2.0.txt for the upstream license.

This HNSW uses Akasha's checked graph access, metrics and deterministic
distance/ID/slot ties. Construction and queries share this traversal.
Rejection counters count checks, which can repeat; distance counters count
actual calls. They deliberately do not claim production counter equivalence.
"""

from akasha.query.control import QueryControl
from akasha.compute.metric import MetricDispatcher
from akasha.index.hnsw_admission import HnswResultAdmission
from akasha.index.hnsw_entries import HnswEntry
from akasha.index.hnsw_heap import HnswHeapItem, _is_better
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.index.hnsw_storage import HnswGraphAccess


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
    var edges = graph.neighbor_range(entry, level)
    for edge_index in range(edges[1]):
        var neighbor = graph.neighbor_at_offset(edges[0] + edge_index)
        if graph.level(neighbor) < level:
            raise Error("HNSW edge targets a node below its graph level")


def choose_entry[
    GraphType: HnswGraphAccess, AdmissionType: HnswResultAdmission, backend_tag: Int = -1
](
    graph: GraphType,
    primary: List[HnswEntry],
    extra: List[HnswEntry],
    allowed: AdmissionType,
) raises -> Optional[HnswEntry]:
    """First eligible primary, otherwise highest eligible extra entry."""
    for entry in primary:
        if graph.is_current(entry.slot) and allowed._allows_item(
            entry.slot, graph.id_at(entry.slot)
        ):
            return Optional(entry)
    var best = Optional[HnswEntry]()
    var best_level = -1
    for entry in extra:
        if graph.is_current(entry.slot) and allowed._allows_item(
            entry.slot, graph.id_at(entry.slot)
        ):
            if entry.level >= best_level:
                best = Optional(entry)
                best_level = entry.level
    return best^


def score_points[
    GraphType: HnswGraphAccess, AdmissionType: HnswResultAdmission, backend_tag: Int = -1
](
    graph: GraphType,
    dispatcher: MetricDispatcher,
    prepared: List[Float32],
    mut points: List[UInt32],
    limit: Int,
    allowed: AdmissionType,
    mut stats: HnswSearchStats,
    mut result: List[HnswHeapItem],
    control: Optional[QueryControl] = None,
) raises:
    """Filter in place, cap, then score into a reusable buffer, as Qdrant does."""
    if control:
        control.value().checkpoint(0)
    var count = 0
    for index in range(len(points)):
        var slot = points[index]
        if not graph.is_current(slot):
            stats.inactive_rejections += 1
        elif not allowed._allows_item(slot, graph.id_at(slot)):
            stats.filtered_rejections += 1
        else:
            points[count] = slot
            count += 1
    if limit > 0 and count > limit:
        count = limit
    while len(points) > count:
        _ = points.pop()
    result.clear()
    var offset = 0
    comptime if backend_tag >= 0 and backend_tag <= 2:
        # The existing F32 kernel shares query loads across four admitted rows,
        # retaining each row's scalar/SIMD reduction order and checked access.
        while offset + 4 <= count:
            var slots = SIMD[DType.uint32, 4](0)
            comptime for lane in range(4):
                slots[lane] = points[offset + lane]
            var distances = graph._distance_to_four_f32[backend_tag](
                dispatcher, prepared, slots
            )
            comptime for lane in range(4):
                stats.distance_evaluations += 1
                result.append(
                    HnswHeapItem(slots[lane], graph.id_at(slots[lane]), distances[lane])
                )
            offset += 4
    for i in range(offset, count):
        var slot = points[i]
        var distance = _distance[backend_tag](graph, dispatcher, prepared, slot)
        stats.distance_evaluations += 1
        result.append(HnswHeapItem(slot, graph.id_at(slot), distance))


def _process_candidate(
    item: HnswHeapItem, ef: Int, mut scratch: HnswSearchScratch
) raises:
    # Qdrant enqueues only points admitted into the bounded nearest queue.
    if len(scratch.results) < ef or _is_better(
        item, scratch.results.peek_worst()
    ):
        scratch.results.offer(item, ef)
        scratch.candidates.push(item)


def search_level[
    GraphType: HnswGraphAccess, AdmissionType: HnswResultAdmission, backend_tag: Int = -1
](
    graph: GraphType,
    dispatcher: MetricDispatcher,
    prepared: List[Float32],
    entry: HnswHeapItem,
    level: Int,
    ef: Int,
    allowed: AdmissionType,
    mut scratch: HnswSearchScratch,
    mut stats: HnswSearchStats,
    control: Optional[QueryControl] = None,
) raises -> List[HnswHeapItem]:
    if ef <= 0 or level < 0:
        raise Error(
            "HNSW search requires positive ef and nonnegative level"
        )
    _validate_search_boundary(graph, dispatcher, prepared, entry.slot, level)
    allowed.validate(graph.slot_count())
    if not graph.is_current(entry.slot) or not allowed._allows_item(entry.slot, graph.id_at(entry.slot)):
        raise Error("HNSW layer entry must be eligible")
    var bounded_ef = min(ef, graph.slot_count())
    scratch.begin(graph.slot_count(), bounded_ef)
    _ = scratch.visit(entry.slot)
    _process_candidate(entry, bounded_ef, scratch)
    stats.base_visited += 1
    var limit = graph.graph_m0() if level == 0 else graph.graph_m()
    var points = List[UInt32](capacity=2 * limit)
    var scored = List[HnswHeapItem](capacity=limit)
    while not scratch.candidates.is_empty():
        if control:
            control.value().checkpoint(0)
        var candidate = scratch.candidates.pop()
        if candidate.distance > scratch.results.peek_worst().distance:
            break
        points.clear()
        var edges = graph.neighbor_range(candidate.slot, level)
        for i in range(edges[1]):
            var neighbor = graph.neighbor_at_offset(edges[0] + i)
            if graph.level(neighbor) < level:
                raise Error("HNSW edge targets a node below its level")
            # Qdrant marks scored nodes, not rejected or truncated neighbors.
            if scratch.visited_epochs[Int(neighbor)] != scratch.epoch:
                points.append(neighbor)
        score_points[backend_tag=backend_tag](
            graph, dispatcher, prepared, points, limit, allowed, stats, scored,
            control=control,
        )
        for item in scored:
            _process_candidate(item, bounded_ef, scratch)
            _ = scratch.visit(item.slot)
            stats.base_visited += 1
    return scratch.results.take_sorted_best()


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
    var current_item = search_entry[backend_tag=backend_tag](
        graph, dispatcher, prepared, entry.value().slot, entry.value().level,
        0, allowed, stats,
        control=control,
    )
    var breadth = ef if ef >= k else k
    var results = search_level[backend_tag=backend_tag](
        graph,
        dispatcher,
        prepared,
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


def _distance[backend_tag: Int, GraphType: HnswGraphAccess](
    graph: GraphType, dispatcher: MetricDispatcher, prepared: List[Float32], slot: UInt32
) raises -> Float32:
    comptime if backend_tag < 0:
        return graph.distance_to_slot(dispatcher, prepared, slot)
    else:
        return graph._distance_to_slot_backend[backend_tag](dispatcher, prepared, slot)


def search_entry[
    GraphType: HnswGraphAccess, AdmissionType: HnswResultAdmission, backend_tag: Int = -1
](
    graph: GraphType, dispatcher: MetricDispatcher, prepared: List[Float32],
    entry: UInt32, highest: Int, lowest: Int, allowed: AdmissionType,
    mut stats: HnswSearchStats,
    control: Optional[QueryControl] = None,
) raises -> HnswHeapItem:
    if control:
        control.value().checkpoint(0)
    _validate_search_boundary(graph, dispatcher, prepared, entry, highest)
    if lowest < 0 or lowest > highest:
        raise Error("HNSW descent level range is invalid")
    allowed.validate(graph.slot_count())
    if not graph.is_current(entry) or not allowed._allows_item(entry, graph.id_at(entry)):
        raise Error("HNSW descent entry must be eligible")
    var current = entry
    var current_item = HnswHeapItem(current, graph.id_at(current), 0.0)
    var points = List[UInt32](capacity=2 * graph.graph_m0())
    var scored = List[HnswHeapItem](capacity=graph.graph_m())
    for level in range(highest, lowest, -1):
        current_item = HnswHeapItem(
            current,
            graph.id_at(current),
            _distance[backend_tag](graph, dispatcher, prepared, current),
        )
        stats.distance_evaluations += 1
        stats.upper_visited += 1
        while True:
            if control:
                control.value().checkpoint(0)
            points.clear()
            var edges = graph.neighbor_range(current_item.slot, level)
            for i in range(edges[1]):
                var neighbor = graph.neighbor_at_offset(edges[0] + i)
                if graph.level(neighbor) < level:
                    raise Error("HNSW edge targets a node below its level")
                points.append(neighbor)
            score_points[backend_tag=backend_tag](
                graph,
                dispatcher,
                prepared,
                points,
                graph.graph_m(),
                allowed,
                stats,
                scored,
                control=control,
            )
            stats.upper_visited += len(scored)
            var changed = False
            for item in scored:
                # Upstream upper descent moves only on strictly better score.
                if item.distance < current_item.distance:
                    current_item = item
                    changed = True
            if not changed:
                break
        current = current_item.slot
    if highest <= lowest:
        current_item = HnswHeapItem(
            current,
            graph.id_at(current),
            _distance[backend_tag](graph, dispatcher, prepared, current),
        )
        stats.distance_evaluations += 1
    return current_item
