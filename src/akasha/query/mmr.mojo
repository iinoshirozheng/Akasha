"""Qdrant MMR selection, revision 74f3e85b9473c62560006c043e13737ce6b48412.

Port of shard/src/query/mmr/mod.rs::maximal_marginal_relevance (Apache-2.0).
Preserves IndexSet insertion/swap-removal order, last-wins ties, OrderedFloat
NaN/zero semantics and separately rounded F32 products. No final score sort.
"""

from akasha.query.control import QueryControl
from akasha.compute.f32 import rounded_f32_product
from std.math import isfinite, isnan


struct MmrOptions(Copyable, Movable):
    var diversity: Float32
    var candidates_limit: Int

    def __init__(out self, diversity: Float32 = 0.5, candidates_limit: Int = -1):
        self.diversity = diversity
        self.candidates_limit = candidates_limit

    def candidate_count(self, k: Int) raises -> Int:
        if not isfinite(self.diversity) or self.diversity < 0 or self.diversity > 1:
            raise Error("MMR diversity must be finite and between 0 and 1")
        if self.candidates_limit < -1 or self.candidates_limit > 16_384:
            raise Error("MMR candidates_limit must be between 0 and 16384")
        if k <= 0:
            raise Error("k must be positive")
        return k if self.candidates_limit == -1 else self.candidates_limit


trait MmrSimilarity:
    def get_similarity(mut self, i: Int, j: Int, control: Optional[QueryControl]) raises -> Float32:
        ...


def _ordered_ge(left: Float32, right: Float32) -> Bool:
    # OrderedFloat treats signed zeros as equal and every NaN as the maximum.
    return isnan(left) or (not isnan(right) and left >= right)


def maximal_marginal_relevance[Matrix: MmrSimilarity](
    relevance: List[Float32], mut matrix: Matrix, lambda_value: Float32,
    limit: Int, control: Optional[QueryControl] = None,
) raises -> List[Int]:
    if control:
        control.value().checkpoint(0)
    var selected = List[Int]()
    if limit <= 0 or len(relevance) == 0:
        return selected^
    var remaining = List[Int]()
    var best = 0
    for i in range(len(relevance)):
        if control:
            control.value().checkpoint(i)
        remaining.append(i)
        if _ordered_ge(relevance[i], relevance[best]):
            best = i
    selected.append(best)
    remaining.swap_elements(best, len(remaining) - 1)
    _ = remaining.pop()
    var visited = 0
    while len(selected) < limit and len(remaining) > 0:
        if control:
            control.value().checkpoint(0)
        var best_position = 0
        var best_score = Float32(0)
        for position in range(len(remaining)):
            var candidate = remaining[position]
            var maximum = Float32(0)
            for selected_position in range(len(selected)):
                if control:
                    control.value().checkpoint(visited)
                visited += 1
                var similarity = matrix.get_similarity(candidate, selected[selected_position], control)
                if selected_position == 0 or _ordered_ge(similarity, maximum):
                    maximum = similarity
            var score = rounded_f32_product(lambda_value, relevance[candidate]) - rounded_f32_product(Float32(1) - lambda_value, maximum)
            if position == 0 or _ordered_ge(score, best_score):
                best_position = position
                best_score = score
        selected.append(remaining[best_position])
        remaining.swap_elements(best_position, len(remaining) - 1)
        _ = remaining.pop()
    if control:
        control.value().checkpoint(0)
    return selected^
