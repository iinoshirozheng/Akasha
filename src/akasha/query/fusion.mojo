from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult
from std.math import isfinite


def rrf_position_score(
    position: Int, rank_constant: Int, weight: Float32 = 1,
) -> Float32:
    """Qdrant reciprocal_rank_fusion.rs position_score, Apache-2.0.

    Ported from 74f3e85b9473c62560006c043e13737ce6b48412; see
    THIRD_PARTY_NOTICES.md and docs/upstream/ports.json.
    Preserve its F32 operation order, including rounding at large constants.
    """
    if weight <= 0:
        return 0
    return Float32(1) / (
        Float32(position + 1) / weight + Float32(rank_constant) - Float32(1)
    )


def validate_rrf_weights(
    weights: Optional[List[Float32]], branch_count: Int,
) raises:
    if weights:
        if len(weights.value()) != branch_count:
            raise Error("RRF weights must match the number of branches")
        for weight in weights.value():
            if not isfinite(weight):
                raise Error("RRF weights must be finite Float32 values")


struct _FusionScore(TrivialRegisterPassable, Writable):
    var id: Int
    var score: Float32

    def __init__(out self, id: Int, score: Float32):
        self.id = id
        self.score = score


def reciprocal_rank_fusion(
    dense: List[SearchResult],
    sparse: List[SearchResult],
    k: Int,
    rank_constant: Int = 2,
    weights: Optional[List[Float32]] = None,
) raises -> List[SearchResult]:
    """Fuse two best-first rankings with deterministic RRF scores."""
    if k <= 0:
        raise Error("k must be positive")
    if rank_constant <= 0:
        raise Error("RRF rank constant must be positive")
    validate_rrf_weights(weights, 2)
    var scores = List[_FusionScore]()
    var score_slots = Dict[Int, Int]()
    _accumulate(
        scores, score_slots, dense, rank_constant,
        weights.value()[0] if weights else Float32(1),
    )
    _accumulate(
        scores, score_slots, sparse, rank_constant,
        weights.value()[1] if weights else Float32(1),
    )
    if len(scores) == 0:
        return List[SearchResult]()
    var capacity = k
    if capacity > len(scores):
        capacity = len(scores)
    var topk = BoundedTopK(capacity, smaller_is_better=False)
    for score in scores:
        topk.offer(score.id, score.score)
    var retained = topk.sorted_entries()
    var result = List[SearchResult](capacity=len(retained))
    for entry in retained:
        result.append(SearchResult(entry.id, entry.score))
    return result^


def _accumulate(
    mut scores: List[_FusionScore],
    mut score_slots: Dict[Int, Int],
    ranking: List[SearchResult],
    rank_constant: Int,
    weight: Float32,
) raises:
    for index in range(len(ranking)):
        var contribution = rrf_position_score(index, rank_constant, weight)
        if not isfinite(contribution):
            raise Error("RRF fusion exceeds finite Float32 range")
        var found = score_slots.get(ranking[index].id, -1)
        if found < 0:
            score_slots[ranking[index].id] = len(scores)
            scores.append(_FusionScore(ranking[index].id, contribution))
        else:
            scores[found].score += contribution
            if not isfinite(scores[found].score):
                raise Error("RRF fusion exceeds finite Float32 range")
