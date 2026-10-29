"""Qdrant discovery/context reducers, ported from revision 74f3e85b9473c625.

segment/vector_storage/query/{context_query,discover_query}.rs, Apache-2.0.
See THIRD_PARTY_NOTICES.md and docs/upstream/ports.json. Preserve F32 arithmetic,
Rust total_cmp ranks and f32::min's non-NaN operand selection.
"""

from akasha.query.recommendation import _total_greater, scaled_fast_sigmoid


def context_pair_rank(positive: Float32, negative: Float32) -> Int:
    if _total_greater(positive, negative):
        return 1
    if _total_greater(negative, positive):
        return -1
    return 0


def context_pair_loss(positive: Float32, negative: Float32) -> Float32:
    var difference = positive - negative - Float32(1.1920928955078125e-7)
    var loss = difference if difference <= Float32(0) else Float32(0)
    return loss / (Float32(1) + abs(loss))


struct DiscoveryScores(Movable):
    var has_target: Bool
    var rank: Int
    var loss: Float32

    def __init__(out self, has_target: Bool):
        self.has_target = has_target
        self.rank = 0
        self.loss = 0

    def add(mut self, positive: Float32, negative: Float32):
        if self.has_target:
            self.rank += context_pair_rank(positive, negative)
        else:
            self.loss += context_pair_loss(positive, negative)

    def finish(self, target_similarity: Float32 = 0) -> Float32:
        if self.has_target:
            return Float32(self.rank) + scaled_fast_sigmoid(target_similarity)
        return self.loss
