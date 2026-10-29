"""Prepared Qdrant discovery/context scoring over native stored vectors.

Qdrant 74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0.
"""

from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.query.control import QueryControl
from akasha.query.discovery import DiscoveryScores
from akasha.query.field_scorer import PreparedFieldQuery
from akasha.query.recommendation_metrics import prepare_recommendation_vector, recommendation_similarity
from std.math import inf, isnan, nan


struct PreparedDiscovery(PreparedFieldQuery, Movable):
    var field: VectorFieldSpec
    var target: Optional[VectorValue]
    var positive: List[VectorValue]
    var negative: List[VectorValue]

    def __init__(
        out self, field: VectorFieldSpec, target: Optional[VectorValue],
        positive: List[VectorValue], negative: List[VectorValue],
    ) raises:
        if len(positive) != len(negative):
            raise Error("discovery requires complete context pairs")
        self.field = field.copy()
        self.target = None
        if target:
            self.target = Optional(prepare_recommendation_vector(target.value(), field))
        self.positive = List[VectorValue]()
        self.negative = List[VectorValue]()
        for i in range(len(positive)):
            self.positive.append(prepare_recommendation_vector(positive[i], field))
            self.negative.append(prepare_recommendation_vector(negative[i], field))

    def query_name(self) -> String:
        return "discovery" if self.target else "context"

    def similarity_count(self) -> Int:
        return 2 * len(self.positive) + Int(Bool(self.target))

    def score(self, stored: VectorValue, control: Optional[QueryControl]) raises -> Float32:
        if control:
            control.value().checkpoint(0)
        var candidate = prepare_recommendation_vector(stored, self.field)
        var reducer = DiscoveryScores(Bool(self.target))
        for i in range(len(self.positive)):
            if control:
                control.value().checkpoint(0)
            reducer.add(
                recommendation_similarity(self.positive[i], candidate, self.field),
                recommendation_similarity(self.negative[i], candidate, self.field),
            )
        if self.target:
            return reducer.finish(recommendation_similarity(self.target.value(), candidate, self.field))
        return reducer.finish()

    def ranking_score(self, score: Float32) -> Float32:
        # Upstream ScoredPointOffset uses OrderedFloat: every NaN ranks above
        # finite numbers. Final discovery/context scores are bounded or NaN,
        # never infinity, so +inf is an unambiguous heap-only sentinel. Negating
        # it for distance-based HNSW preserves the same ordering.
        return inf[DType.float32]() if isnan(score) else score

    def public_score(self, score: Float32) -> Float32:
        return nan[DType.float32]() if score == inf[DType.float32]() else score
