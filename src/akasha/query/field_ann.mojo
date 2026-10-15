from akasha.compute.field_metrics import (
    _score_validated_field,
    validate_field_query,
)
from akasha.compute.topk import BoundedTopK
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.bitmap import Bitmap
from akasha.index.field_hnsw import FieldHnswIndex
from akasha.index.field_artifacts import FieldRow
from akasha.index.field_dense import dense_f32_projection
from akasha.index.flat import SearchResult
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_payload import attach_payload_graphs
from akasha.index.metadata import MetadataIndex
from akasha.document.record import clone_fields
from akasha.index.hnsw_core import HnswEligibility, HnswIdOrdinalLookup
from akasha.index.hnsw_stats import HnswSearchStats, copy_search_stats
from akasha.query.field_search import (
    FieldSearchExecution,
    field_exact_stats,
    gather_field_rows,
    search_generation_field_reported,
)
from akasha.query.control import QueryControl
from akasha.query.planner import QueryPlanner
from akasha.query.filter_ast import FilterExpression
from akasha.storage.read_generation import ReadGeneration
from std.collections import Dict
from std.memory import ArcPointer
from std.utils import BlockingScopedLock


def _build_field_graph(
    view: ReadGeneration,
    field: VectorFieldSpec,
    control: Optional[QueryControl],
    var rows: List[FieldRow],
) raises -> FieldHnswIndex:
    var index = HnswIndex(field.hnsw.value())
    var lookup = Dict[Int, Int]()
    var metadata = MetadataIndex()
    metadata.begin_bulk()
    for row in range(len(rows)):
        if control:
            control.value().checkpoint(row)
        ref location = rows[row]
        ref entry = view.run(location.layer).memtable.entry_ref_at(
            location.ordinal
        )
        ref value = entry.vector_at(entry.field_ordinal(field.id)).value()
        value.validate(field)
        if field.scalar == 0:
            index.add(location.id, value.dense_values[DType.float32]())
        else:
            var converted = dense_f32_projection(value)
            index.add(location.id, converted)
        lookup[location.id] = row
        metadata.upsert(location.id, clone_fields(entry.fields()))
    metadata.finish_bulk()
    attach_payload_graphs(index, metadata, control)
    index.validate_structure()
    var domain = HnswIdOrdinalLookup(lookup^, len(rows))
    return FieldHnswIndex(index^, rows^, domain^)


def _field_graph(
    view: ReadGeneration,
    field: VectorFieldSpec,
    control: Optional[QueryControl],
    var rows: List[FieldRow],
) raises -> ArcPointer[FieldHnswIndex]:
    var state = view.field_hnsw[].get(field.id)
    with BlockingScopedLock(state[].lock):
        if control:
            control.value().checkpoint(0)
        if state[].ready:
            return state[].ready.value().copy()
        try:
            state[].begin()
            if control:
                control.value().checkpoint(0)
            var built = ArcPointer(_build_field_graph(view, field, control, rows^))
            if control:
                control.value().checkpoint(0)
            state[].publish(built.copy())
            return built^
        except error:
            state[].fail(String(error))
            raise error^


def search_generation_field_approx(
    view: ReadGeneration,
    field: VectorFieldSpec,
    query: VectorValue,
    k: Int,
    expression: Optional[FilterExpression],
    ef_search: Int,
    rerank_k: Int,
    control: Optional[QueryControl] = None,
) raises -> FieldSearchExecution:
    if k <= 0:
        raise Error("k must be positive")
    validate_field_query(query, field)
    if expression:
        expression.value().validate()
    if field.kind != 0 or field.index != 1 or not field.hnsw:
        raise Error("approximate field search requires configured dense HNSW")
    ref config = field.hnsw.value()
    var ef = config.default_ef_search if ef_search == -1 else ef_search
    if ef <= 0 or ef > config.max_ef_search:
        raise Error("field HNSW ef exceeds configured bounds")
    if rerank_k < 0 or (rerank_k > 0 and rerank_k < k):
        raise Error("field rerank count must be zero or at least k")
    var budget = max(k, ef) if rerank_k == 0 else rerank_k
    if budget > config.max_ef_search:
        raise Error("field rerank count exceeds configured HNSW maximum")
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(view.visible_count)
    # Determine field presence and filter cardinality before constructing an
    # expensive derived graph. Reuse the captured root's rows once available.
    var cached = Optional[ArcPointer[FieldHnswIndex]]()
    var state = view.field_hnsw[].get(field.id)
    with BlockingScopedLock(state[].lock):
        if state[].ready:
            cached = Optional(state[].ready.value().copy())
    var rows = List[FieldRow]()
    var total: Int
    if cached:
        total = len(cached.value()[].rows)
    else:
        rows = gather_field_rows(view, field.id, control)
        total = len(rows)
    var matched = total
    var eligible = List[Int]()
    if expression:
        for layer in range(view.layer_count()):
            ref table = view.run(layer).memtable
            for ordinal in view.filtered_ordinals(layer, expression.value()):
                if control:
                    control.value().checkpoint(len(eligible))
                ref entry = table.entry_ref_at(ordinal)
                if entry.field_ordinal(field.id) >= 0:
                    eligible.append(entry.id)
        matched = len(eligible)
    if matched == 0:
        var empty_stats = field_exact_stats(field)
        empty_stats.requested_ef = ef
        return FieldSearchExecution([], empty_stats^, "field_empty")
    var plan = QueryPlanner.plan_dense(
        total, matched, k, ef, config.max_ef_search,
        Bool(expression), True, True,
    )
    if not plan.use_hnsw:
        var exact = search_generation_field_reported(
            view, field, query, k, expression, control
        )
        exact.reason = "field_" + plan.reason
        exact.stats.fallback_reason = exact.reason.copy()
        exact.stats.requested_ef = ef
        return exact^
    if not cached:
        cached = Optional(_field_graph(view, field, control, rows^))
    var graph = cached.take()
    var graph_query = dense_f32_projection(query)
    var allowed = Optional[HnswEligibility]()
    if expression:
        var bitmap = Bitmap(total)
        for id in eligible:
            var row = graph[].lookup.ordinal_for(id)
            if row < 0:
                raise Error("field graph coverage differs from its read root")
            bitmap.set(row)
        allowed = Optional(HnswEligibility(bitmap^, graph[].lookup))
    var candidates: List[SearchResult]
    var stats: HnswSearchStats
    with BlockingScopedLock(graph[].query_lock):
        if control:
            control.value().checkpoint(0)
        if allowed:
            candidates = graph[].index.search_allowed_candidates_with_widening(
                graph_query,
                min(budget, matched),
                max(ef, budget),
                config.max_ef_search,
                allowed.value(),
                control=control,
            )
        else:
            candidates = graph[].index.search(
                graph_query, min(budget, matched), ef_search=max(ef, budget), control=control
            )
        stats = copy_search_stats(graph[].index.last_search_stats)
    if control:
        control.value().checkpoint(0)
    var target = min(k, matched)
    if len(candidates) < target:
        var fallback = search_generation_field_reported(
            view, field, query, k, expression, control
        )
        fallback.reason = "field_ann_exhausted"
        fallback.stats.fallback_reason = "field_ann_exhausted"
        fallback.stats.requested_ef = ef
        fallback.stats.effective_ef = stats.effective_ef
        fallback.stats.distance_evaluations += stats.distance_evaluations
        fallback.stats.base_visited += stats.base_visited
        fallback.stats.upper_visited = stats.upper_visited
        fallback.stats.backend_name = "mixed"
        return fallback^
    var topk = BoundedTopK[DType.float64](
        target, smaller_is_better=field.metric == 1
    )
    var reranked = min(budget, len(candidates))
    for ranked in range(reranked):
        if control:
            control.value().checkpoint(ranked)
        ref candidate = candidates[ranked]
        var row = graph[].lookup.ordinal_for(candidate.id)
        if row < 0 or (allowed and not allowed.value().allows(candidate.id)):
            raise Error("field HNSW returned an invalid candidate")
        ref location = graph[].rows[row]
        ref entry = view.run(location.layer).memtable.entry_ref_at(
            location.ordinal
        )
        ref value = entry.vector_at(entry.field_ordinal(field.id)).value()
        topk.offer(candidate.id, _score_validated_field(query, value, field))
    if control:
        control.value().checkpoint(0)
    var results = topk.sorted_entries()
    stats.storage_name = String("field-hnsw-", config.scalar_name())
    stats.requested_ef = ef
    stats.base_candidates = len(candidates)
    stats.reranked_candidates = reranked
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "field_ann")
