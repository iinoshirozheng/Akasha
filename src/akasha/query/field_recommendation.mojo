"""Captured-root recommendation execution; Qdrant recommendation source port.

Lookup/exclusions: collection/recommendations.rs at
74f3e85b9473c62560006c043e13737ce6b48412 (Apache-2.0).
Exact execution is the correctness baseline for subsequent custom ANN scorers.
"""

from akasha.compute.topk import BoundedTopK
from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.index.sparse import sparse_score_is_eligible
from akasha.query.control import QueryControl
from akasha.query.field_lookup import resolve_point_field, same_collection_roots
from akasha.query.field_search import FieldSearchExecution, field_exact_stats
from akasha.query.filter_ast import FilterExpression
from akasha.query.recommendation import RecommendationScores, average_recommendation, validate_recommendation
from akasha.query.recommendation_metrics import prepare_recommendation_vector, recommendation_input, recommendation_similarity
from akasha.storage.read_generation import ReadGeneration
from std.math import isfinite, sqrt


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
    var prepared_positive = List[VectorValue]()
    var prepared_negative = List[VectorValue]()
    if strategy == "average_vector":
        var average = average_recommendation(positive, negative)
        prepared_positive.append(prepare_recommendation_vector(average, field))
    else:
        for example_index in range(len(positive)):
            ref example = positive[example_index]
            prepared_positive.append(prepare_recommendation_vector(example, field))
        for example_index in range(len(negative)):
            ref example = negative[example_index]
            prepared_negative.append(prepare_recommendation_vector(example, field))
    var stats = field_exact_stats(field)
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
            var field_ordinal = entry.field_ordinal(field.id)
            if field_ordinal < 0:
                continue
            ref stored = entry.vector_at(field_ordinal).value()
            if field.kind == 2 and stored.row_count() == 0:
                continue
            var candidate = prepare_recommendation_vector(stored, field)
            var score: Float32
            if strategy == "average_vector":
                score = recommendation_similarity(prepared_positive[0], candidate, field)
                stats.distance_evaluations += 1
                if not isfinite(score):
                    raise Error("recommendation score must be finite")
                # Sparse nearest search omits zeros; custom scores do not.
                if field.kind == 1 and not sparse_score_is_eligible(score):
                    continue
            else:
                var reducer = RecommendationScores(strategy == "best_score")
                for example_index in range(len(prepared_positive)):
                    ref example = prepared_positive[example_index]
                    if control:
                        control.value().checkpoint(0)
                    reducer.add(recommendation_similarity(example, candidate, field), False)
                    stats.distance_evaluations += 1
                for example_index in range(len(prepared_negative)):
                    ref example = prepared_negative[example_index]
                    if control:
                        control.value().checkpoint(0)
                    reducer.add(recommendation_similarity(example, candidate, field), True)
                    stats.distance_evaluations += 1
                score = reducer.finish()
            if not isfinite(score):
                raise Error("recommendation score must be finite")
            topk.offer(entry.id, Float64(score))
            stats.base_visited += 1
    if control:
        control.value().checkpoint(0)
    var results = topk.sorted_entries()
    # Only the nearest-vector strategy applies Euclid public postprocessing.
    if strategy == "average_vector" and field.metric == 1:
        for i in range(len(results)):
            results[i].score = Float64(sqrt(abs(Float32(results[i].score))))
    stats.retained_candidates = len(results)
    return FieldSearchExecution(results^, stats^, "recommendation_exact")
