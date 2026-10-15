from akasha.compute.topk import BoundedTopK
from akasha.index.flat import SearchResult


def rrf_position_score(position: Int, rank_constant: Int) -> Float32:
    """Qdrant reciprocal_rank_fusion.rs position_score with unit weight.

    Preserve its F32 operation order, including rounding at large constants.
    """
    return Float32(1) / (Float32(position + 1) + Float32(rank_constant) - Float32(1))


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
) raises -> List[SearchResult]:
    """Fuse two best-first rankings with deterministic RRF scores."""
    if k <= 0:
        raise Error("k must be positive")
    if rank_constant <= 0:
        raise Error("RRF rank constant must be positive")
    var scores = List[_FusionScore]()
    var score_slots = Dict[Int, Int]()
    _accumulate(scores, score_slots, dense, rank_constant)
    _accumulate(scores, score_slots, sparse, rank_constant)
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
):
    for index in range(len(ranking)):
        var contribution = rrf_position_score(index, rank_constant)
        var found = score_slots.get(ranking[index].id, -1)
        if found < 0:
            score_slots[ranking[index].id] = len(scores)
            scores.append(_FusionScore(ranking[index].id, contribution))
        else:
            scores[found].score += contribution
