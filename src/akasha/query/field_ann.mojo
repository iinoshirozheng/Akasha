from akasha.compute.field_metrics import (
    _score_validated_field,
    _score_four_validated_dense,
    validate_field_query,
)
from akasha.compute.topk import BoundedTopK
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.field_hnsw import FieldHnswIndex
from akasha.index.field_artifacts import FieldRow
from akasha.index.field_dense import dense_f32_projection
from akasha.index.flat import SearchResult
from akasha.index.hnsw import HnswIndex
from akasha.index.hnsw_core import HnswSearchAdmission, HnswIdOrdinalLookup
from akasha.index.hnsw_stats import HnswSearchStats, copy_search_stats
from akasha.query.field_search import (
    FieldSearchExecution,
    field_exact_stats,
    search_generation_field_reported,
)
from akasha.query.control import QueryControl
from akasha.query.filter_ast import FilterExpression
from akasha.storage.read_generation import ReadGeneration, ReadRun
from akasha.storage.field_hnsw_cache import load_field_hnsw_cache
from std.collections import Dict
from std.memory import ArcPointer
from std.utils import BlockingScopedLock


def _build_field_graph(
    run: ReadRun,
    field: VectorFieldSpec,
    control: Optional[QueryControl],
) raises -> FieldHnswIndex:
    var locations = List[FieldRow]()
    ref table = run.memtable
    for ordinal in table.live_ordinals():
        if control:
            control.value().checkpoint(ordinal)
        ref entry = table.entry_ref_at(ordinal)
        if entry.field_ordinal(field.id) >= 0:
            locations.append(FieldRow(entry.id, 0, ordinal))
    sort(Span(locations))
    var rows = List[Int](capacity=len(locations))
    var index = HnswIndex(field.hnsw.value())
    var lookup = Dict[Int, Int]()
    for row in range(len(locations)):
        if control:
            control.value().checkpoint(row)
        ref location = locations[row]
        ref entry = table.entry_ref_at(location.ordinal)
        ref value = entry.vector_at(entry.field_ordinal(field.id)).value()
        value.validate(field)
        if field.scalar == 0:
            index.add(location.id, value.dense_values[DType.float32]())
        else:
            var converted = dense_f32_projection(value)
            index.add(location.id, converted)
        # This append-only graph's slot order is the sorted run row order.
        # Validate that identity once before admitting by slot during searches.
        if index.graph.id_at(UInt32(row)) != location.id:
            raise Error("field graph slot differs from its immutable run row")
        lookup[location.id] = row
        rows.append(location.ordinal)
    index.validate_structure()
    var domain = HnswIdOrdinalLookup(lookup^, len(rows))
    return FieldHnswIndex(index^, rows^, field.scalar, domain^)


def _field_graph(
    run: ReadRun,
    field: VectorFieldSpec,
    control: Optional[QueryControl],
) raises -> ArcPointer[FieldHnswIndex]:
    var state = run.field_hnsw[].get(field.id)
    with BlockingScopedLock(state[].lock):
        if control:
            control.value().checkpoint(0)
        if state[].ready:
            ref ready = state[].ready.value()[]
            if (
                ready.authority_scalar != field.scalar
                or ready.index.config != field.hnsw.value()
            ):
                raise Error("field graph identity differs from its immutable run")
            return state[].ready.value().copy()
        try:
            state[].begin()
            if control:
                control.value().checkpoint(0)
            var loaded = load_field_hnsw_cache(
                run.field_cache_directory, run.memtable, field
            )
            var built = ArcPointer(
                loaded.take() if loaded else _build_field_graph(run, field, control)
            )
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
    var graph_query = dense_f32_projection(query)
    var merged = BoundedTopK[DType.float32](
        min(budget, max(1, view.visible_count)),
        smaller_is_better=field.metric == 1,
    )
    var matched = 0
    var stats = HnswSearchStats()
    for layer in range(view.layer_count()):
        if control:
            control.value().checkpoint(0)
        var graph = _field_graph(view.run(layer), field, control)
        var run_matched = len(graph[].rows)
        var allowed = Optional[HnswSearchAdmission]()
        if expression:
            var flags = List[Bool](length=len(graph[].rows), fill=False)
            run_matched = 0
            var ordinals = view.filtered_ordinals(layer, expression.value())
            ref table = view.run(layer).memtable
            for ordinal in ordinals:
                ref entry = table.entry_ref_at(ordinal)
                if entry.field_ordinal(field.id) < 0:
                    continue
                var row = graph[].lookup.ordinal_for(entry.id)
                if row < 0:
                    raise Error("field graph coverage differs from its read run")
                if not flags[row]:
                    flags[row] = True
                    run_matched += 1
            allowed = Optional(HnswSearchAdmission(flags^))
        elif view.layers[layer].is_shadowed():
            # The graph contains only live, present rows of this run. Exclude
            # shadowed IDs directly instead of walking every visible base row.
            var flags = List[Bool](length=len(graph[].rows), fill=True)
            ref table = view.run(layer).memtable
            for ordinal in view.layers[layer].sealed_hidden[]:
                var row = graph[].lookup.ordinal_for(table.id_at(ordinal))
                if row >= 0 and flags[row]:
                    flags[row] = False
                    run_matched -= 1
            for ordinal in view.layers[layer].head_hidden:
                var row = graph[].lookup.ordinal_for(table.id_at(ordinal))
                if row >= 0 and flags[row]:
                    flags[row] = False
                    run_matched -= 1
            allowed = Optional(HnswSearchAdmission(flags^))
        matched += run_matched
        if run_matched == 0:
            continue
        var candidates: List[SearchResult]
        var run_stats: HnswSearchStats
        with BlockingScopedLock(graph[].query_lock):
            if control:
                control.value().checkpoint(0)
            if allowed:
                candidates = graph[].index._search_admitted_candidates_with_widening(
                    graph_query,
                    min(budget, run_matched),
                    max(ef, budget),
                    config.max_ef_search,
                    run_matched,
                    allowed.value(),
                )
            else:
                candidates = graph[].index.search(
                    graph_query, min(budget, run_matched), ef_search=max(ef, budget)
                )
            run_stats = copy_search_stats(graph[].index.last_search_stats)
        stats.effective_ef = max(stats.effective_ef, run_stats.effective_ef)
        stats.widening_rounds += run_stats.widening_rounds
        stats.upper_visited += run_stats.upper_visited
        stats.base_visited += run_stats.base_visited
        stats.distance_evaluations += run_stats.distance_evaluations
        stats.filtered_rejections += run_stats.filtered_rejections
        stats.inactive_rejections += run_stats.inactive_rejections
        stats.backend_name = run_stats.backend_name.copy()
        stats.metric_name = run_stats.metric_name.copy()
        stats.scalar_name = run_stats.scalar_name.copy()
        if layer == 0:
            stats.base_candidates += len(candidates)
        else:
            stats.delta_candidates += len(candidates)
        for candidate in candidates:
            var row = graph[].lookup.ordinal_for(candidate.id)
            if row < 0 or (allowed and not allowed.value().allows(UInt32(row))):
                raise Error("field HNSW returned an invalid candidate")
            merged.offer(candidate.id, candidate.score)
    if matched == 0:
        var empty_stats = field_exact_stats(field)
        empty_stats.requested_ef = ef
        return FieldSearchExecution([], empty_stats^, "field_empty")
    var candidates = merged.sorted_entries()
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
    var ranked = 0
    while reranked - ranked >= 4:
        # Borrow four checked native values directly from their read runs.
        if control:
            control.value().checkpoint(ranked + 0)
        var a_location = view.find(candidates[ranked + 0].id)
        if a_location[0] < 0:
            raise Error("field HNSW returned an invisible candidate")
        ref a_entry = view.run(a_location[0]).memtable.entry_ref_at(a_location[1])
        var a_ordinal = a_entry.field_ordinal(field.id)
        if a_ordinal < 0:
            raise Error("field HNSW returned a missing field")
        ref a = a_entry.vector_at(a_ordinal).value()
        if control:
            control.value().checkpoint(ranked + 1)
        var b_location = view.find(candidates[ranked + 1].id)
        if b_location[0] < 0:
            raise Error("field HNSW returned an invisible candidate")
        ref b_entry = view.run(b_location[0]).memtable.entry_ref_at(b_location[1])
        var b_ordinal = b_entry.field_ordinal(field.id)
        if b_ordinal < 0:
            raise Error("field HNSW returned a missing field")
        ref b = b_entry.vector_at(b_ordinal).value()
        if control:
            control.value().checkpoint(ranked + 2)
        var c_location = view.find(candidates[ranked + 2].id)
        if c_location[0] < 0:
            raise Error("field HNSW returned an invisible candidate")
        ref c_entry = view.run(c_location[0]).memtable.entry_ref_at(c_location[1])
        var c_ordinal = c_entry.field_ordinal(field.id)
        if c_ordinal < 0:
            raise Error("field HNSW returned a missing field")
        ref c = c_entry.vector_at(c_ordinal).value()
        if control:
            control.value().checkpoint(ranked + 3)
        var d_location = view.find(candidates[ranked + 3].id)
        if d_location[0] < 0:
            raise Error("field HNSW returned an invisible candidate")
        ref d_entry = view.run(d_location[0]).memtable.entry_ref_at(d_location[1])
        var d_ordinal = d_entry.field_ordinal(field.id)
        if d_ordinal < 0:
            raise Error("field HNSW returned a missing field")
        ref d = d_entry.vector_at(d_ordinal).value()
        var scores = _score_four_validated_dense(query, a, b, c, d, field)
        for lane in range(4):
            topk.offer(candidates[ranked + lane].id, Float64(scores[lane]))
        ranked += 4
    for tail in range(ranked, reranked):
        if control:
            control.value().checkpoint(tail)
        ref candidate = candidates[tail]
        var location = view.find(candidate.id)
        if location[0] < 0:
            raise Error("field HNSW returned an invisible candidate")
        ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
        if entry.field_ordinal(field.id) < 0:
            raise Error("field HNSW returned a missing field")
        ref value = entry.vector_at(entry.field_ordinal(field.id)).value()
        topk.offer(candidate.id, _score_validated_field(query, value, field))
    if control:
        control.value().checkpoint(0)
    var results = topk.sorted_entries()
    stats.storage_name = String("field-hnsw-", config.scalar_name())
    stats.requested_ef = ef
    stats.reranked_candidates = reranked
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "field_ann")
