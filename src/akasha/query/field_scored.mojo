"""Exact and HNSW execution over a prepared custom query and captured read root.

Custom point scoring follows Qdrant QueryScorer/FilteredScorer at
74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0. Traversal remains the
existing source-derived HNSW core; filtering precedes candidate scoring.
"""

from akasha.compute.topk import BoundedTopK
from akasha.document.vector_schema import VectorFieldSpec
from akasha.index.field_hnsw import FieldHnswIndex
from akasha.index.hnsw_core import HnswSearchAdmission, search_scored_allowed_with_widening_core
from akasha.index.hnsw_query_scorer import HnswQueryScorer
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_storage import HnswGraphAccess
from akasha.query.control import QueryControl
from akasha.query.field_ann import _field_graph
from akasha.query.field_search import FieldSearchExecution, field_exact_stats, gather_field_rows
from akasha.query.filter_ast import FilterExpression
from akasha.query.planner import QueryPlanner
from akasha.query.field_scorer import PreparedFieldQuery
from akasha.storage.read_generation import ReadGeneration, ReadRun
from std.memory import ArcPointer
from std.utils import BlockingScopedLock


def search_scored_field_exact[QueryType: PreparedFieldQuery](
    view: ReadGeneration, field: VectorFieldSpec, query: QueryType, k: Int,
    expression: Optional[FilterExpression], excluded: Dict[Int, Bool],
    control: Optional[QueryControl],
    required_ids: Optional[Dict[Int, Bool]] = None,
) raises -> FieldSearchExecution:
    var stats = field_exact_stats(field)
    stats.backend_name = String("qdrant-", query.query_name(), "-f32")
    if control:
        control.value().checkpoint(0)
    if view.visible_count == 0:
        return FieldSearchExecution([], stats^, query.query_name() + "_exact")
    var topk = BoundedTopK[DType.float64](min(k, view.visible_count), smaller_is_better=False)
    var scanned = 0
    for layer in range(view.layer_count()):
        var ordinals = view.filtered_ordinals(layer, expression.value()) if expression else view.visible_ordinals(layer)
        ref table = view.run(layer).memtable
        for slot in ordinals:
            if control:
                control.value().checkpoint(scanned)
            scanned += 1
            ref entry = table.entry_ref_at(slot)
            if entry.id in excluded or (required_ids and entry.id not in required_ids.value()):
                stats.filtered_rejections += 1
                continue
            var field_ordinal = entry.field_ordinal(field.id)
            if field_ordinal < 0:
                continue
            ref stored = entry.vector_at(field_ordinal).value()
            if field.kind == 2 and stored.row_count() == 0:
                continue
            var score = query.score(stored, control)
            stats.distance_evaluations += query.similarity_count()
            topk.offer(entry.id, Float64(query.ranking_score(score)))
            stats.base_visited += 1
    if control:
        control.value().checkpoint(0)
    var results = topk.sorted_entries()
    for i in range(len(results)):
        results[i].score = Float64(query.public_score(Float32(results[i].score)))
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, query.query_name() + "_exact")


@fieldwise_init
struct FieldPointScorer[QueryType: PreparedFieldQuery](HnswQueryScorer, Movable):
    var field: VectorFieldSpec
    var run: ArcPointer[ReadRun]
    var mapping: ArcPointer[FieldHnswIndex]
    var query: ArcPointer[Self.QueryType]

    def validate[GraphType: HnswGraphAccess](self, graph: GraphType) raises:
        if graph.slot_count() != len(self.mapping[].rows):
            raise Error("custom query graph coverage differs from its read run")
        if graph.graph_dimension() != self.field.dimension:
            raise Error("custom query dimension differs from HNSW graph")

    def distance[backend_tag: Int, GraphType: HnswGraphAccess](
        self, graph: GraphType, slot: UInt32, control: Optional[QueryControl],
    ) raises -> Float32:
        if UInt64(slot) >= UInt64(len(self.mapping[].rows)):
            raise Error("custom query graph slot out of bounds")
        ref entry = self.run[].memtable.entry_ref_at(self.mapping[].rows[Int(slot)])
        if entry.id != graph.id_at(slot):
            raise Error("custom query graph slot identity mismatch")
        var ordinal = entry.field_ordinal(self.field.id)
        if ordinal < 0:
            raise Error("custom query graph candidate has no vector")
        # Qdrant custom scoring uses each original query example against the
        # stored candidate. Negation adapts its similarity to our distance heap.
        return -self.query[].ranking_score(self.query[].score(entry.vector_at(ordinal).value(), control))

    def distance_four[backend_tag: Int, GraphType: HnswGraphAccess](
        self, graph: GraphType, slots: SIMD[DType.uint32, 4], control: Optional[QueryControl],
    ) raises -> SIMD[DType.float32, 4]:
        var distances = SIMD[DType.float32, 4](0)
        for lane in range(4):
            distances[lane] = self.distance[backend_tag](graph, slots[lane], control)
        return distances

    def public_score(self, distance: Float32) -> Float32:
        # Keep internal similarity until per-run results have been merged.
        return -distance

    def backend_name(self) -> String:
        return String("qdrant-", self.query[].query_name(), "-f32")

    def metric_name(self) -> String:
        return field_exact_stats(self.field).metric_name.copy()

    def scalar_name(self) -> String:
        return field_exact_stats(self.field).scalar_name.copy()


def validate_scored_field_options(field: VectorFieldSpec, k: Int, ef_search: Int) raises -> Int:
    if field.kind != 0 or field.index != 1 or not field.hnsw:
        raise Error("approximate custom query requires configured dense HNSW")
    ref config = field.hnsw.value()
    var ef = config.default_ef_search if ef_search == -1 else ef_search
    if ef <= 0 or ef > config.max_ef_search or k > config.max_ef_search:
        raise Error("custom query HNSW ef or k exceeds configured bounds")
    return ef


def search_scored_field_approx[QueryType: PreparedFieldQuery](
    view: ReadGeneration, field: VectorFieldSpec, query: ArcPointer[QueryType], k: Int,
    expression: Optional[FilterExpression], excluded: Dict[Int, Bool],
    ef_search: Int, control: Optional[QueryControl],
    entry_query: Optional[ArcPointer[QueryType]] = None,
    required_ids: Optional[Dict[Int, Bool]] = None,
) raises -> FieldSearchExecution:
    if control:
        control.value().checkpoint(0)
    var ef = validate_scored_field_options(field, k, ef_search)
    ref config = field.hnsw.value()
    var rows = gather_field_rows(view, field.id, control)
    var eligible_count = 0
    for layer in range(view.layer_count()):
        var ordinals = view.filtered_ordinals(layer, expression.value()) if expression else view.visible_ordinals(layer)
        for scan_index in range(len(ordinals)):
            if control:
                control.value().checkpoint(scan_index)
            var ordinal = ordinals[scan_index]
            ref entry = view.run(layer).memtable.entry_ref_at(ordinal)
            if entry.id not in excluded and entry.field_ordinal(field.id) >= 0 and (not required_ids or entry.id in required_ids.value()):
                eligible_count += 1
    var stats = field_exact_stats(field)
    stats.backend_name = String("qdrant-", query[].query_name(), "-f32")
    stats.requested_ef = ef
    if eligible_count == 0:
        return FieldSearchExecution([], stats^, query[].query_name() + "_empty")
    var plan = QueryPlanner.plan_dense(
        len(rows), eligible_count, k, ef, config.max_ef_search,
        Bool(expression) or len(excluded) > 0 or Bool(required_ids), True, True,
    )
    if not plan.use_hnsw:
        var exact = search_scored_field_exact(view, field, query[], k, expression, excluded, control, required_ids)
        exact.reason = query[].query_name() + "_" + plan.reason
        exact.stats.fallback_reason = exact.reason.copy()
        exact.stats.requested_ef = ef
        return exact^
    var topk = BoundedTopK[DType.float64](min(k, eligible_count), smaller_is_better=False)
    for layer in range(view.layer_count()):
        if control:
            control.value().checkpoint(0)
        var graph = _field_graph(view.run(layer), field, control)
        var flags = List[Bool](length=len(graph[].rows), fill=False)
        var matched = 0
        var ordinals = view.filtered_ordinals(layer, expression.value()) if expression else view.visible_ordinals(layer)
        for scan_index in range(len(ordinals)):
            if control:
                control.value().checkpoint(scan_index)
            var ordinal = ordinals[scan_index]
            ref entry = view.run(layer).memtable.entry_ref_at(ordinal)
            if entry.id in excluded or entry.field_ordinal(field.id) < 0 or (required_ids and entry.id not in required_ids.value()):
                continue
            var row = graph[].lookup.ordinal_for(entry.id)
            if row < 0:
                raise Error("custom query graph coverage differs from its read run")
            if not flags[row]:
                flags[row] = True
                matched += 1
        if matched == 0:
            continue
        var allowed = HnswSearchAdmission(flags^)
        var scorer = FieldPointScorer(field.copy(), view.layers[layer].run.copy(), graph.copy(), query.copy())
        var scratch = HnswSearchScratch()
        with BlockingScopedLock(graph[].query_lock):
            var custom_entries = Optional[List[UInt32]]()
            if entry_query:
                # Qdrant discover_search_with_graph first searches context for
                # ten entry candidates. It does not use nearest-target scores.
                var entry_count = min(10, matched)
                var context_scorer = FieldPointScorer(field.copy(), view.layers[layer].run.copy(), graph.copy(), entry_query.value().copy())
                var context_outcome = search_scored_allowed_with_widening_core(
                    graph[].index.graph, context_scorer, entry_count,
                    max(entry_count, ef), max(entry_count, config.max_ef_search),
                    matched, False, False, graph[].index.entries,
                    String("field-hnsw-", config.scalar_name()), allowed, scratch, control=control,
                )
                stats.upper_visited += context_outcome.stats.upper_visited
                stats.base_visited += context_outcome.stats.base_visited
                stats.distance_evaluations += context_outcome.stats.distance_evaluations * entry_query.value()[].similarity_count()
                stats.filtered_rejections += context_outcome.stats.filtered_rejections
                stats.inactive_rejections += context_outcome.stats.inactive_rejections
                stats.widening_rounds += context_outcome.stats.widening_rounds
                stats.effective_ef = max(stats.effective_ef, context_outcome.stats.effective_ef)
                var entry_slots = List[UInt32]()
                for candidate in context_outcome.take_results():
                    var slot = graph[].lookup.ordinal_for(candidate.id)
                    if slot < 0:
                        raise Error("context entry is absent from its graph")
                    entry_slots.append(UInt32(slot))
                custom_entries = Optional(entry_slots^)
            var outcome = search_scored_allowed_with_widening_core(
                graph[].index.graph, scorer, min(k, matched), max(k, ef),
                config.max_ef_search, matched, True, False, graph[].index.entries,
                String("field-hnsw-", config.scalar_name()), allowed, scratch,
                control=control, custom_entries=custom_entries,
            )
            ref run_stats = outcome.stats
            stats.effective_ef = max(stats.effective_ef, run_stats.effective_ef)
            stats.widening_rounds += run_stats.widening_rounds
            stats.upper_visited += run_stats.upper_visited
            stats.base_visited += run_stats.base_visited
            stats.distance_evaluations += run_stats.distance_evaluations * query[].similarity_count()
            stats.filtered_rejections += run_stats.filtered_rejections
            stats.inactive_rejections += run_stats.inactive_rejections
            var candidates = outcome.take_results()
            if layer == 0:
                stats.base_candidates += len(candidates)
            else:
                stats.delta_candidates += len(candidates)
            for candidate in candidates:
                topk.offer(candidate.id, Float64(candidate.score))
    var results = topk.sorted_entries()
    if len(results) < min(k, eligible_count):
        var exact = search_scored_field_exact(view, field, query[], k, expression, excluded, control, required_ids)
        exact.reason = query[].query_name() + "_ann_exhausted"
        exact.stats.fallback_reason = exact.reason.copy()
        exact.stats.requested_ef = ef
        exact.stats.effective_ef = stats.effective_ef
        exact.stats.widening_rounds = stats.widening_rounds
        exact.stats.upper_visited = stats.upper_visited
        exact.stats.base_visited += stats.base_visited
        exact.stats.distance_evaluations += stats.distance_evaluations
        exact.stats.filtered_rejections += stats.filtered_rejections
        exact.stats.inactive_rejections += stats.inactive_rejections
        exact.stats.base_candidates = stats.base_candidates
        exact.stats.delta_candidates = stats.delta_candidates
        return exact^
    if control:
        control.value().checkpoint(0)
    for i in range(len(results)):
        results[i].score = Float64(query[].public_score(Float32(results[i].score)))
    stats.retained_candidates = len(results)
    stats.storage_name = String("field-hnsw-", config.scalar_name())
    return FieldSearchExecution(results^, stats^, query[].query_name() + "_hnsw")
