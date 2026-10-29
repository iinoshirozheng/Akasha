"""Captured-root discovery/context, Qdrant collection/discovery.rs port.

Revision 74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0.
"""

from akasha.document.vector_value import VectorValue
from akasha.index.hnsw_stats import HnswSearchStats
from akasha.query.control import QueryControl
from akasha.query.discovery_scorer import PreparedDiscovery
from akasha.query.field_examples import RecommendationExample, resolve_query_example
from akasha.query.field_lookup import same_collection_roots
from akasha.query.field_scored import search_scored_field_exact, search_scored_field_approx
from akasha.query.field_search import FieldSearchExecution
from akasha.query.filter_ast import FilterExpression
from akasha.storage.read_generation import ReadGeneration
from std.memory import ArcPointer


@fieldwise_init
struct ContextPair(Movable):
    var positive: RecommendationExample
    var negative: RecommendationExample


def discover_generation_field(
    view: ReadGeneration, source: ReadGeneration, name: String,
    target: Optional[RecommendationExample], context: List[ContextPair],
    k: Int, expression: Optional[FilterExpression], *,
    lookup_field: Optional[String] = None, max_examples: Int = 1024,
    control: Optional[QueryControl] = None,
    approximate: Bool = False, ef_search: Int = -1,
) raises -> FieldSearchExecution:
    if k < 0:
        raise Error("discovery k must be nonnegative")
    if k == 0:
        return FieldSearchExecution([], HnswSearchStats(), "discovery_zero_limit")
    if not target and len(context) == 0:
        raise Error("target and/or context pairs must be specified")
    if max_examples <= 0 or len(context) > (max_examples - Int(Bool(target))) // 2:
        raise Error("discovery example resource limit exceeded")
    if control:
        control.value().checkpoint(0)
        control.value().validate_candidate_count(view.visible_count)
    if expression:
        expression.value().validate()
    if not view.catalog:
        raise Error("discovery requires a field-aware collection")
    ref catalog = view.catalog.value()[]
    var ordinal = catalog.named_ordinal(name)
    if ordinal < 0:
        raise Error("unknown named vector field")
    ref field = catalog.field_at(ordinal)
    if field.kind == 3:
        raise Error("binary discovery is not supported by Qdrant")
    var same = same_collection_roots(view, source)
    var source_name = lookup_field.value() if lookup_field else name
    var excluded = Dict[Int, Bool]()
    var resolved_target = Optional[VectorValue]()
    if target:
        resolved_target = Optional(resolve_query_example(target.value(), source, source_name, field, same, excluded))
    var positive = List[VectorValue]()
    var negative = List[VectorValue]()
    for i in range(len(context)):
        if control:
            control.value().checkpoint(i)
        positive.append(resolve_query_example(context[i].positive, source, source_name, field, same, excluded))
        negative.append(resolve_query_example(context[i].negative, source, source_name, field, same, excluded))
    var query = ArcPointer(PreparedDiscovery(field, resolved_target, positive, negative))
    if field.kind == 1:
        if ef_search != -1:
            raise Error("ef_search is only valid for dense HNSW discovery")
        # Qdrant sparse custom scoring uses all eligible vectors, including
        # no-overlap and zero-score candidates, regardless of SearchParams.
        var result = search_scored_field_exact(view, query[].field, query[], k, expression, excluded, control)
        result.reason = query[].query_name() + "_sparse_scored"
        return result^
    if approximate:
        var entry_query = Optional[ArcPointer[PreparedDiscovery]]()
        if target:
            entry_query = Optional(ArcPointer(PreparedDiscovery(field, None, positive, negative)))
        return search_scored_field_approx(view, query[].field, query, k, expression, excluded, ef_search, control, entry_query)
    if ef_search != -1:
        raise Error("ef_search requires approximate discovery")
    return search_scored_field_exact(view, query[].field, query[], k, expression, excluded, control)
