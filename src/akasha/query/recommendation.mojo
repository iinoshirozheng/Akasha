"""Qdrant recommendation transforms and score reducers.

Ported from Qdrant 74f3e85b9473c62560006c043e13737ce6b48412:
collection/recommendations.rs, sparse/common/sparse_vector.rs,
segment/vector_storage/query/reco_query.rs and common/common/src/math.rs.
Apache-2.0; see THIRD_PARTY_NOTICES.md and docs/upstream/ports.json.
Inputs to transforms are owned F32 query values, as in the upstream API.
"""

from akasha.document.vector_value import VectorValue
from akasha.index.sparse import SparseElement
from std.math import inf, isfinite
from std.memory import bitcast


def validate_recommendation(strategy: String, positives: Int, negatives: Int) raises:
    if strategy != "average_vector" and strategy != "best_score" and strategy != "sum_scores":
        raise Error("unknown recommendation strategy")
    if positives == 0 and (strategy == "average_vector" or negatives == 0):
        raise Error("recommendation requires examples; average_vector requires positives")


def _combine_sparse(
    left: List[SparseElement], right: List[SparseElement], subtract: Bool,
) -> List[SparseElement]:
    # combine_aggregate calls op for absent terms too, supplying zero.
    var result = List[SparseElement]()
    var i = 0
    var j = 0
    while i < len(left) or j < len(right):
        var term: Int
        var a = Float32(0)
        var b = Float32(0)
        if j == len(right) or (i < len(left) and left[i].term_id < right[j].term_id):
            term = left[i].term_id
            a = left[i].weight
            i += 1
        elif i == len(left) or right[j].term_id < left[i].term_id:
            term = right[j].term_id
            b = right[j].weight
            j += 1
        else:
            term = left[i].term_id
            a = left[i].weight
            b = right[j].weight
            i += 1
            j += 1
        result.append(SparseElement(term, a + a - b if subtract else a + b))
    return result^


def average_recommendation_vectors(vectors: List[VectorValue]) raises -> VectorValue:
    if len(vectors) == 0:
        raise Error("positive vectors should not be empty with average strategy")
    var kind = vectors[0].kind()
    var dimension = vectors[0].dimension()
    var dense = List[Float32]()
    var sparse = List[SparseElement]()
    for vector_index in range(len(vectors)):
        ref vector = vectors[vector_index]
        if vector.kind() != kind or vector.scalar() != 0:
            raise Error("recommendation transform requires matching F32 vector kinds")
        if kind != 1 and vector.dimension() != dimension:
            raise Error("recommendation vector dimension mismatch")
        if kind == 0:
            ref values = vector.dense_values[DType.float32]()
            for i in range(len(values)):
                if i == len(dense):
                    dense.append(values[i])
                else:
                    dense[i] += values[i]
        elif kind == 1:
            sparse = _combine_sparse(vector.sparse_values(), sparse, False)
        elif kind == 2:
            for value in vector.multivector_values[DType.float32]():
                dense.append(value)
        else:
            raise Error("binary recommendation is not supported by Qdrant")
    if kind == 1:
        for i in range(len(sparse)):
            sparse[i].weight /= Float32(len(vectors))
        return VectorValue.sparse(sparse^)
    if kind == 2:
        return VectorValue.multivector[DType.float32](dimension, dense^)
    for i in range(len(dense)):
        dense[i] /= Float32(len(vectors))
    return VectorValue.dense[DType.float32](dense^)


def merge_recommendation_averages(positive: VectorValue, negative: VectorValue) raises -> VectorValue:
    if positive.kind() != negative.kind() or positive.scalar() != 0 or negative.scalar() != 0:
        raise Error("positive and negative averages must have matching F32 kinds")
    if positive.kind() == 1:
        return VectorValue.sparse(_combine_sparse(positive.sparse_values(), negative.sparse_values(), True))
    if positive.dimension() != negative.dimension():
        raise Error("recommendation vector dimension mismatch")
    var result = List[Float32]()
    if positive.kind() == 2:
        for value in positive.multivector_values[DType.float32]():
            result.append(value)
        for value in negative.multivector_values[DType.float32]():
            result.append(-value)
        return VectorValue.multivector[DType.float32](positive.dimension(), result^)
    ref left = positive.dense_values[DType.float32]()
    ref right = negative.dense_values[DType.float32]()
    for i in range(len(left)):
        result.append(left[i] + left[i] - right[i])
    return VectorValue.dense[DType.float32](result^)


def average_recommendation(positives: List[VectorValue], negatives: List[VectorValue]) raises -> VectorValue:
    var positive = average_recommendation_vectors(positives)
    if len(negatives) == 0:
        return positive^
    var negative = average_recommendation_vectors(negatives)
    return merge_recommendation_averages(positive, negative)


def _total_greater(a: Float32, b: Float32) -> Bool:
    # Rust f32::total_cmp includes the -0/+0 distinction.
    var left = bitcast[DType.int32](a)
    var right = bitcast[DType.int32](b)
    left ^= Int32(UInt32(left >> 31) >> 1)
    right ^= Int32(UInt32(right >> 31) >> 1)
    return left > right


def scaled_fast_sigmoid(value: Float32) -> Float32:
    return Float32(0.5) * (value / (Float32(1) + abs(value)) + Float32(1))


struct RecommendationScores(Movable):
    """Streaming form of the two upstream score_by loops, without score lists."""

    var best: Bool
    var positive: Float32
    var negative: Float32

    def __init__(out self, best: Bool):
        self.best = best
        self.positive = -inf[DType.float32]() if best else Float32(0)
        self.negative = self.positive

    def add(mut self, score: Float32, negative: Bool) raises:
        if not isfinite(score):
            raise Error("recommendation similarity must be finite")
        if negative:
            if not self.best:
                self.negative += score
            elif _total_greater(score, self.negative):
                self.negative = score
        else:
            if not self.best:
                self.positive += score
            elif _total_greater(score, self.positive):
                self.positive = score

    def finish(self) raises -> Float32:
        var score: Float32
        if not self.best:
            score = self.positive - self.negative
        elif self.positive > self.negative:
            score = scaled_fast_sigmoid(self.positive)
        else:
            score = -scaled_fast_sigmoid(self.negative)
        if not isfinite(score):
            raise Error("recommendation score must be finite")
        return score
