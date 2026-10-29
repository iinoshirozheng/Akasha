"""Execute Qdrant-derived nested query plans on one retained native root.

Sources: planned_query.rs, local_shard/query.rs, collection/query.rs and
collection_query.rs at 74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
"""
from akasha.compute.topk import BoundedTopK
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.hnsw_stats import HnswSearchStats, copy_search_stats
from akasha.query.control import QueryControl
from akasha.query.discovery_scorer import PreparedDiscovery
from akasha.query.evaluator import matches_expression
from akasha.query.field_examples import resolve_query_example
from akasha.query.field_lookup import same_collection_roots
from akasha.query.field_mmr import rerank_generation_mmr
from akasha.query.field_scored import search_scored_field_exact, search_scored_field_approx, validate_scored_field_options
from akasha.query.field_search import FieldSearchExecution, FieldSearchResult, search_sparse_field
from akasha.query.fusion import rrf_position_score
from akasha.query.query_plan import QueryNode, QueryStep, plan_query
from akasha.query.recommendation_scorer import PreparedRecommendation
from akasha.query.recommendation_metrics import recommendation_input
from akasha.query.score_fusion import distribution_normalize
from akasha.storage.read_generation import ReadGeneration
from std.memory import ArcPointer
from std.math import isfinite


@fieldwise_init
struct _PreparedNode(Movable):
    var field: Optional[VectorFieldSpec]
    var recommendation: Optional[ArcPointer[PreparedRecommendation]]
    var discovery: Optional[ArcPointer[PreparedDiscovery]]
    var context: Optional[ArcPointer[PreparedDiscovery]]
    var target: Optional[VectorValue]


def _remaining(control: Optional[QueryControl], used: Int) raises -> Optional[QueryControl]:
    if not control:
        return None
    control.value().checkpoint(0)
    control.value().validate_candidate_count(used)
    var result = control.value().copy()
    result.max_candidates -= used
    return Optional(result^)


def _prepare_nodes(
    view: ReadGeneration, lookups: List[ArcPointer[ReadGeneration]], nodes: List[QueryNode],
    mut excluded: Dict[Int, Bool], control: Optional[QueryControl],
) raises -> List[_PreparedNode]:
    var prepared = List[_PreparedNode]()
    for index in range(len(nodes)):
        ref node = nodes[index]
        if control:
            control.value().checkpoint(0)
        var item = _PreparedNode(None, None, None, None, None)
        if node.kind == "rrf" or node.kind == "dbsf" or node.kind == "scroll" or node.kind == "formula":
            prepared.append(item^)
            continue
        if not view.catalog:
            raise Error("query requires a vector field catalog")
        ref catalog = view.catalog.value()[]
        var ordinal = 0 if node.using == "" else catalog.named_ordinal(node.using)
        if ordinal < 0:
            raise Error("unknown query vector field")
        ref field = catalog.field_at(ordinal)
        if field.kind == 3:
            raise Error("binary universal vector query is not supported by Qdrant")
        if node.lookup_index >= len(lookups):
            raise Error("query lookup index is out of bounds")
        if node.lookup_index >= 0:
            ref source = lookups[node.lookup_index][]
            prepared.append(_prepare_vector_node(field, node, source, same_collection_roots(view, source), excluded, control))
        else:
            prepared.append(_prepare_vector_node(field, node, view, True, excluded, control))
    return prepared^


def _prepare_vector_node(
    field: VectorFieldSpec, node: QueryNode, source: ReadGeneration, same: Bool,
    mut excluded: Dict[Int, Bool], control: Optional[QueryControl],
) raises -> _PreparedNode:
    var item = _PreparedNode(None, None, None, None, None)
    var name = node.lookup_field.value() if node.lookup_field else node.using
    var target = Optional[VectorValue]()
    var positive = List[VectorValue]()
    var negative = List[VectorValue]()
    if node.target:
        target = Optional(resolve_query_example(node.target.value(), source, name, field, same, excluded, allow_default=True))
    for index in range(len(node.positive)):
        if control:
            control.value().checkpoint(0)
        positive.append(resolve_query_example(node.positive[index], source, name, field, same, excluded, allow_default=True))
    for index in range(len(node.negative)):
        if control:
            control.value().checkpoint(0)
        negative.append(resolve_query_example(node.negative[index], source, name, field, same, excluded, allow_default=True))
    item.field = Optional(field.copy())
    if node.kind == "nearest":
        positive.append(recommendation_input(target.value()))
        item.recommendation = Optional(ArcPointer(PreparedRecommendation(field, "average_vector", positive, negative)))
    elif node.kind == "recommend":
        item.recommendation = Optional(ArcPointer(PreparedRecommendation(field, node.strategy, positive, negative)))
    else:
        item.discovery = Optional(ArcPointer(PreparedDiscovery(field, target, positive, negative)))
        if target:
            item.context = Optional(ArcPointer(PreparedDiscovery(field, None, positive, negative)))
    item.target = target^
    return item^


def _candidate_ids(
    view: ReadGeneration, nodes: List[QueryNode], steps: List[QueryStep], index: Int,
    results: List[List[FieldSearchResult]], excluded: Dict[Int, Bool],
    control: Optional[QueryControl],
) raises -> Optional[Dict[Int, Bool]]:
    var has_filter = False
    var current = index
    while current >= 0:
        has_filter = has_filter or Bool(nodes[current].filter)
        current = steps[current].parent
    var required = Dict[Int, Bool]()
    var has_children = len(nodes[index].children) > 0
    if has_children:
        # Qdrant filter_with_sources_ids takes a set union, not intersection.
        for child in nodes[index].children:
            for hit in results[child]:
                required[hit.id] = True
    if not has_filter:
        return Optional(required^) if has_children else None
    var filtered = Dict[Int, Bool]()
    var seen = 0
    for layer in range(view.layer_count()):
        for ordinal in view.visible_ordinals(layer):
            if control:
                control.value().checkpoint(seen)
            seen += 1
            ref entry = view.run(layer).memtable.entry_ref_at(ordinal)
            if entry.id in excluded or (has_children and entry.id not in required):
                continue
            var admit = True
            current = index
            while current >= 0 and admit:
                if nodes[current].filter:
                    admit = matches_expression(entry.fields(), nodes[current].filter.value())
                current = steps[current].parent
            if admit:
                filtered[entry.id] = True
    return Optional(filtered^)


def _merge_stats(mut total: HnswSearchStats, stats: HnswSearchStats):
    total.requested_ef = max(total.requested_ef, stats.requested_ef)
    total.effective_ef = max(total.effective_ef, stats.effective_ef)
    total.widening_rounds += stats.widening_rounds
    total.upper_visited += stats.upper_visited
    total.base_visited += stats.base_visited
    total.distance_evaluations += stats.distance_evaluations
    total.filtered_rejections += stats.filtered_rejections
    total.inactive_rejections += stats.inactive_rejections
    total.reranked_candidates += stats.reranked_candidates
    total.base_candidates += stats.base_candidates
    total.delta_candidates += stats.delta_candidates
    if stats.fallback_reason != "":
        total.fallback_reason = "query_stage_fallback"


def _vector_search(
    view: ReadGeneration, node: QueryNode, prepared: _PreparedNode, limit: Int,
    excluded: Dict[Int, Bool], required: Optional[Dict[Int, Bool]],
    control: Optional[QueryControl],
) raises -> FieldSearchExecution:
    ref field = prepared.field.value()
    if field.kind == 1 and node.ef_search != -1:
        raise Error("ef_search requires dense HNSW")
    if node.approximate and field.kind != 1:
        _ = validate_scored_field_options(field, limit, node.ef_search)
    if limit == 0:
        return FieldSearchExecution([], HnswSearchStats(), "query_zero_candidates")
    if prepared.recommendation:
        ref query = prepared.recommendation.value()
        if field.kind == 1 and query[].strategy == "average_vector":
            if node.ef_search != -1:
                raise Error("ef_search requires dense HNSW")
            return search_sparse_field(view, field, query[].positive[0], limit, None, control,
                Optional(excluded.copy()), required_ids=required, require_finite=True)
        if node.approximate and field.kind != 1:
            return search_scored_field_approx(view, field, query, limit, None, excluded,
                node.ef_search, control, required_ids=required)
        return search_scored_field_exact(view, field, query[], limit, None, excluded, control, required)
    ref query = prepared.discovery.value()
    if node.approximate and field.kind != 1:
        return search_scored_field_approx(view, field, query, limit, None, excluded,
            node.ef_search, control, prepared.context, required)
    if field.kind == 1 and node.ef_search != -1:
        raise Error("ef_search requires dense HNSW")
    return search_scored_field_exact(view, field, query[], limit, None, excluded, control, required)


def _fuse(node: QueryNode, results: List[List[FieldSearchResult]], limit: Int, control: Optional[QueryControl]) raises -> List[FieldSearchResult]:
    var scores = Dict[Int, Float32]()
    for i in range(len(node.children)):
        if control:
            control.value().checkpoint(0)
        ref source = results[node.children[i]]
        var normalized = List[Float32]()
        if node.kind == "dbsf":
            var values = List[Float32]()
            for j in range(len(source)):
                if control:
                    control.value().checkpoint(j)
                values.append(Float32(source[j].score))
            normalized = distribution_normalize(values)
        for rank in range(len(source)):
            if control:
                control.value().checkpoint(rank)
            var contribution = normalized[rank] if node.kind == "dbsf" else rrf_position_score(rank, node.rank_constant, node.weights.value()[i] if node.weights else Float32(1))
            var score = scores.get(source[rank].id, Float32(0)) + contribution
            if not isfinite(score):
                raise Error("query fusion requires finite Float32 scores")
            scores[source[rank].id] = score
    var top = BoundedTopK[DType.float64](max(1, min(limit, len(scores))), smaller_is_better=False)
    var offered = 0
    for id in scores:
        if control:
            control.value().checkpoint(offered)
        offered += 1
        top.offer(id, Float64(scores[id]))
    return top.sorted_entries()


def _formula_rescore(
    view: ReadGeneration, node: QueryNode, results: List[List[FieldSearchResult]],
    limit: Int, control: Optional[QueryControl],
) raises -> FieldSearchExecution:
    # Source segment/read_view/formula_rescore.rs: ordered score maps and a
    # deduplicated visible-head union. A duplicate within a source is last-wins.
    var scores = List[Dict[Int, Float32]]()
    var candidates = Dict[Int, Tuple[Int, Int]]()
    var visited = 0
    for child in node.children:
        var source = Dict[Int, Float32]()
        for hit in results[child]:
            if control:
                control.value().checkpoint(visited)
            visited += 1
            var location = view.find(hit.id)
            if location[0] < 0:
                continue
            candidates[hit.id] = location
            source[hit.id] = Float32(hit.score)
        scores.append(source^)
    var top = BoundedTopK[DType.float64](max(1, min(limit, len(candidates))), smaller_is_better=False)
    for id in candidates:
        if control:
            control.value().checkpoint(0)
        var location = candidates[id]
        ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
        var score = node.formula.value().score(id, entry.fields(), scores, control)
        top.offer(id, Float64(score))
    var stats = HnswSearchStats()
    stats.reranked_candidates = len(candidates)
    return FieldSearchExecution(top.sorted_entries(), stats^, "query_formula")


def query_generation(
    view: ReadGeneration, lookups: List[ArcPointer[ReadGeneration]], nodes: List[QueryNode], *,
    control: Optional[QueryControl] = None, max_nodes: Int = 1024,
    max_k: Int = 10_000, max_examples: Int = 1024,
) raises -> FieldSearchExecution:
    var steps = plan_query(nodes, max_nodes, max_k, max_examples)
    var excluded = Dict[Int, Bool]()
    var prepared = _prepare_nodes(view, lookups, nodes, excluded, control)
    var results = List[List[FieldSearchResult]]()
    var total = HnswSearchStats()
    total.backend_name = "qdrant-query-f32"
    total.storage_name = "query-plan"
    var used = 0
    var root = len(nodes) - 1
    for i in range(len(nodes)):
        ref node = nodes[i]
        ref step = steps[i]
        var local_control = _remaining(control, used)
        var charge = view.visible_count
        if node.kind == "rrf" or node.kind == "dbsf" or node.kind == "formula" or (step.apply_mmr and i != root):
            charge = 0
            for child in node.children:
                if len(results[child]) > Int.MAX - charge:
                    raise Error("query work count exceeds resource limit")
                charge += len(results[child])
        if local_control:
            local_control.value().validate_candidate_count(charge)
        if charge > Int.MAX - used:
            raise Error("query work count exceeds resource limit")
        used += charge
        var execution = FieldSearchExecution([], HnswSearchStats(), "query_stage")
        if node.kind == "rrf" or node.kind == "dbsf":
            execution.results = _fuse(node, results, step.limit, local_control)
        elif node.kind == "formula":
            execution = _formula_rescore(view, node, results, step.limit, local_control)
        elif step.apply_mmr and i != root:
            # Nested MMR preserves source order and original source scores.
            for child in node.children:
                for hit in results[child]:
                    execution.results.append(hit)
        else:
            var required = _candidate_ids(view, nodes, steps, i, results, excluded, local_control)
            if node.kind == "scroll":
                var top = BoundedTopK[DType.float64](step.limit, smaller_is_better=True)
                var scanned = 0
                for layer in range(view.layer_count()):
                    for ordinal in view.visible_ordinals(layer):
                        if local_control:
                            local_control.value().checkpoint(scanned)
                        scanned += 1
                        var id = view.run(layer).memtable.entry_ref_at(ordinal).id
                        if id not in excluded and (not required or id in required.value()):
                            # Equal score makes bounded TopK sort by exact Int ID.
                            top.offer(id, Float64(0))
                execution.results = top.sorted_entries()
                execution.stats.base_visited = scanned
            else:
                execution = _vector_search(view, node, prepared[i],
                    step.fetch_limit if node.mmr else step.limit, excluded, required, local_control)
        # Source threshold is take_while over score-ordered results, before
        # root MMR. Nested MMR's rescore branch intentionally ignores threshold.
        if node.threshold and not (step.apply_mmr and i != root):
            var kept = List[FieldSearchResult]()
            var small = prepared[i].recommendation and prepared[i].recommendation.value()[].strategy == "average_vector" and prepared[i].field.value().metric == 1
            for hit in execution.results:
                var admit = hit.score <= Float64(node.threshold.value()) if small else hit.score >= Float64(node.threshold.value())
                if not admit:
                    break
                kept.append(hit)
            execution.results = kept^
        if step.apply_mmr:
            _merge_stats(total, execution.stats)
            execution.stats = HnswSearchStats()
            var mmr_control = _remaining(control, used)
            execution = rerank_generation_mmr(view, prepared[i].field.value(), prepared[i].target.value(),
                execution^, node.limit, node.mmr.value().diversity, mmr_control, prior_work=0)
            if execution.stats.distance_evaluations > Int.MAX - used:
                raise Error("query work count exceeds resource limit")
            used += execution.stats.distance_evaluations
            if control:
                control.value().validate_candidate_count(used)
        _merge_stats(total, execution.stats)
        results.append(execution.take_results())
    var output = List[FieldSearchResult]()
    for i in range(nodes[root].offset, min(len(results[root]), nodes[root].offset + nodes[root].limit)):
        output.append(results[root][i])
    total.retained_candidates = len(output)
    if control:
        control.value().checkpoint(0)
    return FieldSearchExecution(output^, total^, "query_plan")
