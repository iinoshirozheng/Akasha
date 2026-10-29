"""Exact, HNSW and sparse execution over a prepared recommendation/read root.

Custom point scoring follows Qdrant QueryScorer/FilteredScorer at
74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0. Traversal remains the
existing source-derived HNSW core; filtering precedes candidate scoring.
"""

from akasha.compute.topk import BoundedTopK
from akasha.index.field_hnsw import FieldHnswIndex
from akasha.index.hnsw_core import HnswSearchAdmission, search_scored_allowed_with_widening_core
from akasha.index.hnsw_query_scorer import HnswQueryScorer
from akasha.index.hnsw_scratch import HnswSearchScratch
from akasha.index.hnsw_storage import HnswGraphAccess
from akasha.index.sparse_search import search_sparse_postings
from akasha.query.control import QueryControl
from akasha.query.evaluator import matches_expression
from akasha.query.field_ann import _field_graph
from akasha.query.field_search import FieldSearchExecution, FieldSearchResult, field_exact_stats, gather_field_rows, _sparse_artifact
from akasha.query.filter_ast import FilterExpression
from akasha.query.planner import QueryPlanner
from akasha.query.recommendation_scorer import PreparedRecommendation
from akasha.storage.read_generation import ReadGeneration, ReadRun
from std.memory import ArcPointer
from std.utils import BlockingScopedLock


def search_recommendation_exact(
    view: ReadGeneration, query: PreparedRecommendation, k: Int,
    expression: Optional[FilterExpression], excluded: Dict[Int, Bool],
    control: Optional[QueryControl],
) raises -> FieldSearchExecution:
    var stats = field_exact_stats(query.field)
    stats.backend_name = "qdrant-recommendation-f32"
    if control:
        control.value().checkpoint(0)
    if view.visible_count == 0:
        return FieldSearchExecution([], stats^, "recommendation_exact")
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
            if entry.id in excluded:
                stats.filtered_rejections += 1
                continue
            var field_ordinal = entry.field_ordinal(query.field.id)
            if field_ordinal < 0:
                continue
            ref stored = entry.vector_at(field_ordinal).value()
            if query.field.kind == 2 and stored.row_count() == 0:
                continue
            var score = query.score(stored, control)
            stats.distance_evaluations += query.similarity_count()
            topk.offer(entry.id, Float64(score))
            stats.base_visited += 1
    if control:
        control.value().checkpoint(0)
    var results = topk.sorted_entries()
    for i in range(len(results)):
        results[i].score = Float64(query.public_score(Float32(results[i].score)))
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "recommendation_exact")


@fieldwise_init
struct RecommendationPointScorer(HnswQueryScorer, Movable):
    var run: ArcPointer[ReadRun]
    var mapping: ArcPointer[FieldHnswIndex]
    var query: ArcPointer[PreparedRecommendation]

    def validate[GraphType: HnswGraphAccess](self, graph: GraphType) raises:
        if graph.slot_count() != len(self.mapping[].rows):
            raise Error("recommendation graph coverage differs from its read run")
        if graph.graph_dimension() != self.query[].field.dimension:
            raise Error("recommendation dimension differs from HNSW graph")

    def distance[backend_tag: Int, GraphType: HnswGraphAccess](
        self, graph: GraphType, slot: UInt32, control: Optional[QueryControl],
    ) raises -> Float32:
        if UInt64(slot) >= UInt64(len(self.mapping[].rows)):
            raise Error("recommendation graph slot out of bounds")
        ref entry = self.run[].memtable.entry_ref_at(self.mapping[].rows[Int(slot)])
        if entry.id != graph.id_at(slot):
            raise Error("recommendation graph slot identity mismatch")
        var ordinal = entry.field_ordinal(self.query[].field.id)
        if ordinal < 0:
            raise Error("recommendation graph candidate has no vector")
        # Qdrant custom scoring uses each original query example against the
        # stored candidate. Negation adapts its similarity to our distance heap.
        return -self.query[].score(entry.vector_at(ordinal).value(), control)

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
        return "qdrant-recommendation-f32"

    def metric_name(self) -> String:
        return field_exact_stats(self.query[].field).metric_name.copy()

    def scalar_name(self) -> String:
        return field_exact_stats(self.query[].field).scalar_name.copy()


def search_recommendation_approx(
    view: ReadGeneration, query: ArcPointer[PreparedRecommendation], k: Int,
    expression: Optional[FilterExpression], excluded: Dict[Int, Bool],
    ef_search: Int, control: Optional[QueryControl],
) raises -> FieldSearchExecution:
    ref field = query[].field
    if control:
        control.value().checkpoint(0)
    if field.kind != 0 or field.index != 1 or not field.hnsw:
        raise Error("approximate recommendation requires configured dense HNSW")
    ref config = field.hnsw.value()
    var ef = config.default_ef_search if ef_search == -1 else ef_search
    if ef <= 0 or ef > config.max_ef_search or k > config.max_ef_search:
        raise Error("recommendation HNSW ef or k exceeds configured bounds")
    var rows = gather_field_rows(view, field.id, control)
    var eligible_count = 0
    for layer in range(view.layer_count()):
        var ordinals = view.filtered_ordinals(layer, expression.value()) if expression else view.visible_ordinals(layer)
        for scan_index in range(len(ordinals)):
            if control:
                control.value().checkpoint(scan_index)
            var ordinal = ordinals[scan_index]
            ref entry = view.run(layer).memtable.entry_ref_at(ordinal)
            if entry.id not in excluded and entry.field_ordinal(field.id) >= 0:
                eligible_count += 1
    var stats = field_exact_stats(field)
    stats.backend_name = "qdrant-recommendation-f32"
    stats.requested_ef = ef
    if eligible_count == 0:
        return FieldSearchExecution([], stats^, "recommendation_empty")
    var plan = QueryPlanner.plan_dense(
        len(rows), eligible_count, k, ef, config.max_ef_search,
        Bool(expression) or len(excluded) > 0, True, True,
    )
    if not plan.use_hnsw:
        var exact = search_recommendation_exact(view, query[], k, expression, excluded, control)
        exact.reason = "recommendation_" + plan.reason
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
            if entry.id in excluded or entry.field_ordinal(field.id) < 0:
                continue
            var row = graph[].lookup.ordinal_for(entry.id)
            if row < 0:
                raise Error("recommendation graph coverage differs from its read run")
            if not flags[row]:
                flags[row] = True
                matched += 1
        if matched == 0:
            continue
        var allowed = HnswSearchAdmission(flags^)
        var scorer = RecommendationPointScorer(view.layers[layer].run.copy(), graph.copy(), query.copy())
        var scratch = HnswSearchScratch()
        with BlockingScopedLock(graph[].query_lock):
            var outcome = search_scored_allowed_with_widening_core(
                graph[].index.graph, scorer, min(k, matched), max(k, ef),
                config.max_ef_search, matched, True, False, graph[].index.entries,
                String("field-hnsw-", config.scalar_name()), allowed, scratch, control=control,
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
        var exact = search_recommendation_exact(view, query[], k, expression, excluded, control)
        exact.reason = "recommendation_ann_exhausted"
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
    return FieldSearchExecution(results^, stats^, "recommendation_hnsw")


def search_recommendation_sparse(
    view: ReadGeneration, query: PreparedRecommendation, k: Int,
    expression: Optional[FilterExpression], excluded: Dict[Int, Bool],
    control: Optional[QueryControl],
) raises -> FieldSearchExecution:
    """Qdrant sparse search_query: nearest index versus custom full scoring."""
    if query.strategy != "average_vector":
        var execution = search_recommendation_exact(view, query, k, expression, excluded, control)
        execution.reason = "recommendation_sparse_scored"
        return execution^
    var stats = field_exact_stats(query.field)
    stats.backend_name = "qdrant-recommendation-f32"
    stats.storage_name = "field-postings"
    if len(query.positive[0].sparse_values()) == 0:
        return FieldSearchExecution([], stats^, "recommendation_sparse_empty")
    var owner = _sparse_artifact(view, query.field, control)
    var allowed = List[Bool](length=len(owner[].rows), fill=False)
    var matched = 0
    for row in range(len(owner[].rows)):
        if control:
            control.value().checkpoint(row)
        var location = owner[].rows[row]
        if location.id in excluded:
            continue
        ref entry = view.run(location.layer).memtable.entry_ref_at(location.ordinal)
        if expression and not matches_expression(entry.fields(), expression.value()):
            continue
        allowed[row] = True
        matched += 1
    # Source default; exact native cardinality replaces its estimate. Configurable
    # sparse thresholds and IDF remain separate full-protocol/schema work.
    var plain = (Bool(expression) or len(excluded) > 0) and matched < 5_000
    var outcome = search_sparse_postings(owner, query.positive[0].sparse_values(), allowed, k, plain, control)
    var results = List[FieldSearchResult](capacity=len(outcome.results))
    for item in outcome.results:
        results.append(FieldSearchResult(item.id, Float64(item.score)))
    stats.distance_evaluations = outcome.evaluated
    stats.base_visited = outcome.evaluated
    stats.filtered_rejections = outcome.rejected
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "recommendation_sparse_plain" if plain else "recommendation_sparse_indexed")
