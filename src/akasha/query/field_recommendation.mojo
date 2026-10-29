"""Captured-root recommendation execution; Qdrant recommendation source port.

Lookup/exclusions: collection/recommendations.rs at
74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
Exact and indexed execution share one prepared recommendation scorer.
"""

from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.query.control import QueryControl
from akasha.query.field_lookup import same_collection_roots
from akasha.query.field_examples import RecommendationExample, resolve_query_examples
from akasha.query.field_search import FieldSearchExecution, search_sparse_field
from akasha.query.filter_ast import FilterExpression
from akasha.query.recommendation import validate_recommendation
from akasha.query.recommendation_scorer import PreparedRecommendation
from akasha.query.field_scored import search_scored_field_exact, search_scored_field_approx
from akasha.storage.read_generation import ReadGeneration
from std.memory import ArcPointer


def recommend_generation_field(
    view: ReadGeneration, source: ReadGeneration, name: String,
    positives: List[RecommendationExample], negatives: List[RecommendationExample],
    k: Int, strategy: String, expression: Optional[FilterExpression], *,
    lookup_field: Optional[String] = None, max_examples: Int = 1024,
    control: Optional[QueryControl] = None,
    approximate: Bool = False, ef_search: Int = -1,
) raises -> FieldSearchExecution:
    validate_recommendation(strategy, len(positives), len(negatives))
    if k <= 0:
        raise Error("recommendation k must be positive")
    if max_examples <= 0 or len(positives) > max_examples or len(negatives) > max_examples - len(positives):
        raise Error("recommendation example resource limit exceeded")
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(view.visible_count)
    if expression:
        expression.value().validate()
    if not view.catalog:
        raise Error("recommendation requires a field-aware collection")
    ref catalog = view.catalog.value()[]
    var ordinal = catalog.named_ordinal(name)
    if ordinal < 0:
        raise Error("unknown named vector field")
    ref field = catalog.field_at(ordinal)
    if field.kind == 3:
        raise Error("binary recommendation is not supported by Qdrant")
    var same = same_collection_roots(view, source)
    var source_name = lookup_field.value() if lookup_field else name
    var excluded = Dict[Int, Bool]()
    var positive = resolve_query_examples(positives, source, source_name, field, same, excluded, control)
    var negative = resolve_query_examples(negatives, source, source_name, field, same, excluded, control)
    var query = ArcPointer(PreparedRecommendation(field, strategy, positive, negative))
    if field.kind == 1:
        if ef_search != -1:
            raise Error("ef_search is only valid for dense HNSW recommendation")
        # Qdrant's sparse VectorIndex ignores SearchParams (including exact).
        return search_recommendation_sparse(view, query[], k, expression, excluded, control)
    if approximate:
        return search_scored_field_approx(view, query[].field, query, k, expression, excluded, ef_search, control)
    if ef_search != -1:
        raise Error("ef_search requires approximate recommendation")
    return search_scored_field_exact(view, query[].field, query[], k, expression, excluded, control)


def search_recommendation_sparse(
    view: ReadGeneration, query: PreparedRecommendation, k: Int,
    expression: Optional[FilterExpression], excluded: Dict[Int, Bool],
    control: Optional[QueryControl],
) raises -> FieldSearchExecution:
    """Qdrant sparse search_query: nearest index versus custom full scoring."""
    if query.strategy != "average_vector":
        var execution = search_scored_field_exact(view, query.field, query, k, expression, excluded, control)
        execution.reason = "recommendation_sparse_scored"
        return execution^
    var execution = search_sparse_field(
        view, query.field, query.positive[0], k, expression, control,
        Optional(excluded.copy()), require_finite=True,
    )
    execution.stats.backend_name = "qdrant-recommendation-f32"
    if execution.reason == "field_sparse_empty":
        execution.reason = "recommendation_sparse_empty"
    elif execution.reason == "field_sparse_plain":
        execution.reason = "recommendation_sparse_plain"
    else:
        execution.reason = "recommendation_sparse_indexed"
    return execution^
