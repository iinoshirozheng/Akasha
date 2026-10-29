"""Captured-root recommendation execution; Qdrant recommendation source port.

Lookup/exclusions: collection/recommendations.rs at
74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
Exact and indexed execution share one prepared recommendation scorer.
"""

from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.query.control import QueryControl
from akasha.query.field_lookup import resolve_point_field, same_collection_roots
from akasha.query.field_search import FieldSearchExecution
from akasha.query.filter_ast import FilterExpression
from akasha.query.recommendation import validate_recommendation
from akasha.query.recommendation_metrics import prepare_recommendation_vector, recommendation_input
from akasha.query.recommendation_scorer import PreparedRecommendation
from akasha.query.recommendation_execution import search_recommendation_exact, search_recommendation_approx, search_recommendation_sparse
from akasha.storage.read_generation import ReadGeneration
from std.memory import ArcPointer


@fieldwise_init
struct RecommendationExample(Movable):
    var id: Optional[Int]
    var vector: Optional[VectorValue]

    @staticmethod
    def point(id: Int) -> Self:
        return Self(Optional(id), None)

    @staticmethod
    def raw(var value: VectorValue) -> Self:
        return Self(None, Optional(value^))


def _resolve_examples(
    examples: List[RecommendationExample], source: ReadGeneration,
    name: String, field: VectorFieldSpec, same: Bool,
    mut excluded: Dict[Int, Bool], control: Optional[QueryControl],
) raises -> List[VectorValue]:
    var result = List[VectorValue]()
    for i in range(len(examples)):
        if control:
            control.value().checkpoint(i)
        ref example = examples[i]
        var value: VectorValue
        if example.id:
            if example.vector:
                raise Error("recommendation example must contain either ID or vector")
            var point = resolve_point_field(source, name, example.id.value())
            ref catalog = source.catalog.value()[]
            ref source_field = catalog.field_at(catalog.named_ordinal(name))
            # Qdrant retrieves already preprocessed stored vectors. Akasha keeps
            # raw native authority, so reconstruct that representation here.
            value = prepare_recommendation_vector(point.value(), source_field)
            if same:
                excluded[example.id.value()] = True
        elif example.vector:
            value = recommendation_input(example.vector.value())
        else:
            raise Error("recommendation example is empty")
        if value.kind() != field.kind or (field.kind != 1 and value.dimension() != field.dimension):
            raise Error("recommendation vector kind or dimension mismatch")
        if field.kind == 2 and value.row_count() == 0:
            raise Error("recommendation multivector example must have rows")
        result.append(value^)
    return result^


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
    var positive = _resolve_examples(positives, source, source_name, field, same, excluded, control)
    var negative = _resolve_examples(negatives, source, source_name, field, same, excluded, control)
    var query = ArcPointer(PreparedRecommendation(field, strategy, positive, negative))
    if field.kind == 1:
        if ef_search != -1:
            raise Error("ef_search is only valid for dense HNSW recommendation")
        # Qdrant's sparse VectorIndex ignores SearchParams (including exact).
        return search_recommendation_sparse(view, query[], k, expression, excluded, control)
    if approximate:
        return search_recommendation_approx(view, query, k, expression, excluded, ef_search, control)
    if ef_search != -1:
        raise Error("ef_search requires approximate recommendation")
    return search_recommendation_exact(view, query[], k, expression, excluded, control)
