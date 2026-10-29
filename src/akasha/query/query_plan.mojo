"""Qdrant universal-query planning, adapted to a native postorder node arena.

Source: shard/src/query/planned_query.rs and collection_query.rs, revision
74f3e85b9473c62560006c043e13737ce6b48412, Apache-2.0.
"""
from akasha.query.field_examples import RecommendationExample
from akasha.query.filter_ast import FilterExpression
from akasha.query.formula import Formula
from akasha.query.fusion import validate_rrf_weights
from akasha.query.mmr import MmrOptions
from akasha.query.recommendation import validate_recommendation
from std.math import isfinite


struct QueryNode(Movable):
    var kind: String
    var using: String
    var target: Optional[RecommendationExample]
    var positive: List[RecommendationExample]
    var negative: List[RecommendationExample]
    var strategy: String
    var children: List[Int]
    var limit: Int
    var offset: Int
    var threshold: Optional[Float32]
    var filter: Optional[FilterExpression]
    var approximate: Bool
    var ef_search: Int
    var lookup_index: Int
    var lookup_field: Optional[String]
    var mmr: Optional[MmrOptions]
    var rank_constant: Int
    var weights: Optional[List[Float32]]
    var formula: Optional[Formula]

    def __init__(
        out self, kind: String, using: String = "", *,
        var target: Optional[RecommendationExample] = None,
        var positive: List[RecommendationExample] = [],
        var negative: List[RecommendationExample] = [],
        strategy: String = "average_vector", var children: List[Int] = [],
        limit: Int = 10, offset: Int = 0, threshold: Optional[Float32] = None,
        var filter: Optional[FilterExpression] = None, approximate: Bool = False,
        ef_search: Int = -1, lookup_index: Int = -1,
        lookup_field: Optional[String] = None, mmr: Optional[MmrOptions] = None,
        rank_constant: Int = 2, weights: Optional[List[Float32]] = None,
        var formula: Optional[Formula] = None,
    ):
        self.kind = kind
        self.using = using
        self.target = target^
        self.positive = positive^
        self.negative = negative^
        self.strategy = strategy
        self.children = children^
        self.limit = limit
        self.offset = offset
        self.threshold = threshold
        self.filter = filter^
        self.approximate = approximate
        self.ef_search = ef_search
        self.lookup_index = lookup_index
        self.lookup_field = lookup_field.copy()
        self.mmr = mmr.copy()
        self.rank_constant = rank_constant
        self.weights = weights.copy()
        self.formula = formula^


@fieldwise_init
struct QueryStep(Movable):
    var parent: Int
    var depth: Int
    var limit: Int
    var fetch_limit: Int
    var nearest_rescore: Bool
    var apply_mmr: Bool


def plan_query(
    nodes: List[QueryNode], max_nodes: Int = 1024, max_k: Int = 10_000,
    max_examples: Int = 1024,
) raises -> List[QueryStep]:
    if len(nodes) == 0 or len(nodes) > max_nodes or max_nodes <= 0 or max_k <= 0 or max_examples <= 0:
        raise Error("query node resource limit exceeded")
    var root = len(nodes) - 1
    var parents = List[Int](length=len(nodes), fill=-1)
    var steps = List[QueryStep]()
    var examples = 0
    var resources = len(nodes)
    for i in range(len(nodes)):
        ref node = nodes[i]
        if node.limit <= 0 or node.offset < 0 or node.limit > max_k or node.offset > max_k - node.limit:
            raise Error("query limit plus offset exceeds resource limit")
        if i != root and node.offset != 0:
            raise Error("offset is only valid on the root query")
        if node.threshold and not isfinite(node.threshold.value()):
            raise Error("query score threshold must be finite")
        if node.filter:
            node.filter.value().validate()
        if node.lookup_index < -1:
            raise Error("query lookup index is invalid")
        if node.ef_search != -1 and (not node.approximate or node.ef_search <= 0):
            raise Error("ef_search requires an approximate query and must be positive")
        var count = Int(Bool(node.target)) + len(node.positive) + len(node.negative)
        if count > max_examples - examples:
            raise Error("query example resource limit exceeded")
        examples += count
        if node.kind == "nearest":
            if not node.target or len(node.positive) or len(node.negative):
                raise Error("nearest query requires exactly one target")
        elif node.kind == "recommend":
            if node.target:
                raise Error("recommend query cannot have a target")
            validate_recommendation(node.strategy, len(node.positive), len(node.negative))
        elif node.kind == "discover" or node.kind == "context":
            if len(node.positive) != len(node.negative):
                raise Error("query context pairs must be complete")
            if node.kind == "discover" and not node.target:
                raise Error("discover query requires a target")
            if node.kind == "context" and (node.target or len(node.positive) == 0):
                raise Error("context query requires pairs and no target")
        elif node.kind == "rrf" or node.kind == "dbsf" or node.kind == "scroll" or node.kind == "formula":
            if count != 0 or node.using != "" or node.approximate or node.ef_search != -1 or node.lookup_index != -1 or node.lookup_field:
                raise Error("non-vector query cannot specify vector or lookup options")
            if node.kind == "scroll":
                if len(node.children) or node.threshold:
                    raise Error("a query is required for prefetch or score_threshold")
            elif len(node.children) == 0:
                raise Error("cannot apply fusion or formula without prefetches")
        else:
            raise Error("unsupported universal query kind")
        if node.mmr and node.kind != "nearest":
            raise Error("MMR requires a nearest query")
        if node.kind == "formula":
            if not node.formula:
                raise Error("formula query requires an expression")
            node.formula.value().validate()
            var count = len(node.formula.value().nodes) + len(node.formula.value().defaults)
            if count > max_nodes - resources:
                raise Error("query formula resource limit exceeded")
            resources += count
        elif node.formula:
            raise Error("formula expression requires a formula query")
        if node.weights and node.kind != "rrf":
            raise Error("weights require RRF query")
        if node.kind == "rrf":
            if node.rank_constant <= 0:
                raise Error("RRF rank constant must be positive")
            validate_rrf_weights(node.weights, len(node.children))
        var depth = 0
        for child in node.children:
            if child < 0 or child >= i or parents[child] != -1:
                raise Error("query must be an ordered tree with one parent per node")
            parents[child] = i
            depth = max(depth, steps[child].depth + 1)
        if depth > 64:
            raise Error("prefetch depth exceeds maximum 64")
        var limit = node.limit + node.offset
        var fetch = limit
        if node.mmr:
            fetch = node.mmr.value().candidate_count(node.limit)
            if fetch > max_k:
                raise Error("MMR candidate limit exceeds query resource limit")
        # Source: root MMR reselects nearest candidates; nested MMR over
        # prefetches directly diversifies the ordered source union. A leaf
        # prefetch with MMR only contributes its nearest candidates.
        var mmr = Bool(node.mmr)
        steps.append(QueryStep(-1, depth, limit, fetch,
            mmr and i == root and len(node.children) > 0,
            mmr and (i == root or len(node.children) > 0)))
    for i in range(len(nodes)):
        if i != root and parents[i] == -1:
            raise Error("query contains an unreachable node")
        steps[i].parent = parents[i]
    return steps^
