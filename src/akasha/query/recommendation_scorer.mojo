"""Prepared Qdrant recommendation scoring shared by exact and graph queries.

Based on CustomQueryScorer and RecoQuery at Qdrant revision
74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0.
"""

from akasha.document.vector_schema import VectorFieldSpec
from akasha.document.vector_value import VectorValue
from akasha.query.control import QueryControl
from akasha.query.recommendation import RecommendationScores, average_recommendation
from akasha.query.recommendation_metrics import prepare_recommendation_vector, recommendation_similarity
from std.math import isfinite, sqrt


struct PreparedRecommendation(Movable):
    var field: VectorFieldSpec
    var strategy: String
    var positive: List[VectorValue]
    var negative: List[VectorValue]

    def __init__(
        out self, field: VectorFieldSpec, strategy: String,
        positive: List[VectorValue], negative: List[VectorValue],
    ) raises:
        self.field = field.copy()
        self.strategy = strategy.copy()
        self.positive = List[VectorValue]()
        self.negative = List[VectorValue]()
        if strategy == "average_vector":
            var average = average_recommendation(positive, negative)
            self.positive.append(prepare_recommendation_vector(average, field))
        else:
            for i in range(len(positive)):
                self.positive.append(prepare_recommendation_vector(positive[i], field))
            for i in range(len(negative)):
                self.negative.append(prepare_recommendation_vector(negative[i], field))

    def similarity_count(self) -> Int:
        return len(self.positive) + len(self.negative)

    def score(self, stored: VectorValue, control: Optional[QueryControl]) raises -> Float32:
        if control:
            control.value().checkpoint(0)
        var candidate = prepare_recommendation_vector(stored, self.field)
        var score: Float32
        if self.strategy == "average_vector":
            score = recommendation_similarity(self.positive[0], candidate, self.field)
        else:
            var reducer = RecommendationScores(self.strategy == "best_score")
            for i in range(len(self.positive)):
                if control:
                    control.value().checkpoint(0)
                reducer.add(recommendation_similarity(self.positive[i], candidate, self.field), False)
            for i in range(len(self.negative)):
                if control:
                    control.value().checkpoint(0)
                reducer.add(recommendation_similarity(self.negative[i], candidate, self.field), True)
            score = reducer.finish()
        if not isfinite(score):
            raise Error("recommendation score must be finite")
        return score

    def public_score(self, score: Float32) -> Float32:
        if self.strategy == "average_vector" and self.field.metric == 1:
            return sqrt(abs(score))
        return score
