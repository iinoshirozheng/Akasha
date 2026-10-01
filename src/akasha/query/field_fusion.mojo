"""Field-specific retrieval and deterministic F64 RRF on one captured root."""

from akasha.compute.topk import BoundedTopK
from akasha.compute.field_metrics import (
    _score_validated_field,
    validate_field_query,
)
from akasha.document.vector_value import VectorValue
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.query.control import QueryControl
from akasha.query.field_ann import search_generation_field_approx
from akasha.query.field_ivf import search_generation_field_ivf
from akasha.index.field_ivf import IvfOptions
from akasha.query.field_search import (
    FieldSearchExecution,
    field_exact_stats,
    search_generation_field_reported,
)
from akasha.query.filter_ast import FilterExpression
from akasha.storage.read_generation import ReadGeneration


struct FieldQuery(Movable):
    var name: String
    var query: VectorValue
    var approximate: Bool
    var ef_search: Int
    var rerank_k: Int
    var ivf: Optional[IvfOptions]

    def __init__(
        out self,
        name: String,
        var query: VectorValue,
        *,
        approximate: Bool = False,
        ef_search: Int = -1,
        rerank_k: Int = 0,
        ivf: Optional[IvfOptions] = None,
    ):
        self.name = name
        self.query = query^
        self.approximate = approximate
        self.ef_search = ef_search
        self.rerank_k = rerank_k
        self.ivf = ivf.copy()


def search_generation_fields(
    view: ReadGeneration,
    queries: List[FieldQuery],
    k: Int,
    fetch_k: Int,
    rank_constant: Int,
    expression: Optional[FilterExpression],
    control: Optional[QueryControl],
    rerank: Optional[FieldQuery] = None,
) raises -> FieldSearchExecution:
    if k <= 0 or fetch_k < k or rank_constant <= 0 or len(queries) == 0:
        raise Error(
            "field fusion requires positive k, rank constant and branches, with"
            " fetch_k >= k"
        )
    if not view.catalog:
        raise Error("named search requires a field-aware collection")
    if control:
        control.value().checkpoint(0)
        # Count the visible-point budget for every branch without overflowing.
        if view.visible_count > control.value().max_candidates // len(queries):
            raise Error("query candidate resource limit exceeded")
        if rerank and min(
            fetch_k, view.visible_count
        ) > control.value().max_candidates - view.visible_count * len(queries):
            raise Error("query candidate resource limit exceeded")
    ref catalog = view.catalog.value()[]
    var rerank_ordinal = -1
    if rerank:
        ref final = rerank.value()
        if (
            final.approximate
            or final.ef_search != -1
            or final.rerank_k != 0
            or final.ivf
        ):
            raise Error("final field reranking requires an exact FieldQuery")
        rerank_ordinal = catalog.named_ordinal(final.name)
        if rerank_ordinal < 0:
            raise Error("unknown named rerank field")
        validate_field_query(final.query, catalog.field_at(rerank_ordinal))
    var scores = Dict[Int, Float64]()
    var stats = HnswSearchStats()
    stats.backend_name = "native-f64"
    stats.storage_name = "field-fusion"
    stats.scalar_name = "f64"
    stats.metric_name = "rrf"
    for branch in range(len(queries)):
        if control:
            control.value().checkpoint(0)
        ref query = queries[branch]
        var ordinal = catalog.named_ordinal(query.name)
        if ordinal < 0:
            raise Error("unknown named vector field")
        ref field = catalog.field_at(ordinal)
        var execution: FieldSearchExecution
        if query.ivf:
            if (
                query.approximate
                or query.ef_search != -1
                or query.rerank_k != 0
            ):
                raise Error("IVF cannot be combined with HNSW options")
            execution = search_generation_field_ivf(
                view,
                field,
                query.query,
                fetch_k,
                expression,
                query.ivf.value().nlist,
                query.ivf.value().nprobe,
                query.ivf.value().iterations,
                control,
            )
        elif query.approximate:
            stats.backend_name = "mixed"
            execution = search_generation_field_approx(
                view,
                field,
                query.query,
                fetch_k,
                expression,
                query.ef_search,
                query.rerank_k,
                control,
            )
        else:
            if query.ef_search != -1 or query.rerank_k != 0:
                raise Error(
                    "ef_search and rerank_k require approximate field search"
                )
            execution = search_generation_field_reported(
                view, field, query.query, fetch_k, expression, control
            )
        ref ranked = execution.results
        for rank in range(len(ranked)):
            var id = ranked[rank].id
            var contribution = Float64(1) / (
                Float64(rank_constant) + Float64(rank) + 1
            )
            scores[id] = scores.get(id, Float64(0)) + contribution
        stats.requested_ef = max(
            stats.requested_ef, execution.stats.requested_ef
        )
        stats.effective_ef = max(
            stats.effective_ef, execution.stats.effective_ef
        )
        stats.widening_rounds += execution.stats.widening_rounds
        stats.upper_visited += execution.stats.upper_visited
        stats.base_visited += execution.stats.base_visited
        stats.distance_evaluations += execution.stats.distance_evaluations
        stats.reranked_candidates += execution.stats.reranked_candidates
        stats.base_candidates += execution.stats.base_candidates
        stats.filtered_rejections += execution.stats.filtered_rejections
        stats.ivf_partitions += execution.stats.ivf_partitions
        stats.ivf_probed_partitions += execution.stats.ivf_probed_partitions
        if execution.stats.fallback_reason != "":
            stats.fallback_reason = "field_branch_fallback"
    if control:
        control.value().checkpoint(0)
    if len(scores) == 0 and not rerank:
        return FieldSearchExecution([], stats^, "field_fusion")
    var topk = BoundedTopK[DType.float64](
        max(1, min(fetch_k if rerank else k, len(scores))),
        smaller_is_better=False,
    )
    for id in scores:
        topk.offer(id, scores[id])
    var results = topk.sorted_entries()
    if rerank:
        ref field = catalog.field_at(rerank_ordinal)
        var final_stats = field_exact_stats(field)
        stats.backend_name = final_stats.backend_name
        stats.metric_name = final_stats.metric_name
        stats.scalar_name = final_stats.scalar_name
        stats.storage_name = "field-rerank"
        stats.base_candidates = len(results)
        stats.reranked_candidates = 0
        var ranked = BoundedTopK[DType.float64](
            max(1, min(k, len(results))),
            smaller_is_better=field.metric == 1
            or field.metric == 3
            or field.metric == 4,
        )
        for ordinal in range(len(results)):
            if control:
                control.value().checkpoint(ordinal)
            var location = view.find(results[ordinal].id)
            if location[0] < 0:
                raise Error("rerank candidate is missing from captured root")
            ref entry = view.run(location[0]).memtable.entry_ref_at(location[1])
            var field_ordinal = entry.field_ordinal(field.id)
            if field_ordinal < 0:
                continue
            ref value = entry.vector_at(field_ordinal).value()
            if field.kind == 2 and value.row_count() == 0:
                continue
            ranked.offer(
                entry.id,
                _score_validated_field(rerank.value().query, value, field),
            )
            stats.reranked_candidates += 1
            stats.distance_evaluations += 1
        if control:
            control.value().checkpoint(0)
        var final_results = ranked.sorted_entries()
        stats.retained_candidates = len(final_results)
        return FieldSearchExecution(final_results^, stats^, "field_rerank")
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "field_fusion")
