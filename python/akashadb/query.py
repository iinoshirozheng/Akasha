"""Universal query requests; planning and scoring execute in the Mojo kernel."""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Literal, Mapping, Sequence

from .exceptions import ValidationError
from .vectors import MmrOptions, _vector_value

if TYPE_CHECKING:
    from .database import Collection


@dataclass(frozen=True, slots=True)
class QueryRequest:
    """A query node with ordered prefetches. Only the root accepts an offset.

    ``using=""`` selects the default dense vector. Context pairs are parallel
    positive/negative sequences. No-vector ``scroll`` orders points by ID.
    """

    kind: Literal["nearest", "recommend", "discover", "context", "rrf", "dbsf", "scroll"] = "scroll"
    using: str = ""
    target: Any = None
    positive: Sequence[Any] = ()
    negative: Sequence[Any] = ()
    strategy: str = "average_vector"
    prefetch: Sequence[QueryRequest] = ()
    limit: int = 10
    offset: int = 0
    score_threshold: float | None = None
    filter: Mapping[str, Any] | None = None
    mode: Literal["exact", "approx"] = "exact"
    ef_search: int | None = None
    lookup_from: Collection | None = None
    lookup_field: str | None = None
    mmr: MmrOptions | None = None
    rank_constant: int = 2
    weights: Sequence[float] | None = None


def serialize_query(request: QueryRequest, max_nodes: int, max_examples: int) -> list[dict[str, Any]]:
    """Bounded wire serialization, retaining source order and lookup owners."""
    nodes: list[dict[str, Any]] = []
    active: set[int] = set()
    count = examples = 0

    def visit(node: QueryRequest, depth: int) -> int:
        nonlocal count, examples
        count += 1
        if count > max_nodes or depth > 64:
            raise ValidationError("query node or depth resource limit exceeded")
        if not isinstance(node, QueryRequest):
            raise ValidationError("prefetch must contain QueryRequest values")
        if id(node) in active:
            raise ValidationError("query prefetch must not contain a cycle")
        if node.mode not in ("exact", "approx"):
            raise ValidationError("query mode must be exact or approx")
        if node.mmr is not None and not isinstance(node.mmr, MmrOptions):
            raise ValidationError("mmr must be MmrOptions")
        if not all(isinstance(v, (list, tuple)) for v in (node.prefetch, node.positive, node.negative)):
            raise ValidationError("prefetch and query examples must be lists or tuples")
        examples += (node.target is not None) + len(node.positive) + len(node.negative)
        if examples > max_examples:
            raise ValidationError("query example resource limit exceeded")
        active.add(id(node))
        children = [visit(child, depth + 1) for child in node.prefetch]
        active.remove(id(node))
        nodes.append({
            "kind": node.kind, "using": node.using,
            "target": _vector_value(node.target),
            "positive": [_vector_value(x) for x in node.positive],
            "negative": [_vector_value(x) for x in node.negative],
            "strategy": node.strategy, "children": children,
            "limit": node.limit, "offset": node.offset,
            "threshold": node.score_threshold,
            "filter": None if node.filter is None else dict(node.filter),
            "approximate": node.mode == "approx",
            "ef_search": -1 if node.ef_search is None else node.ef_search,
            "lookup_from": node.lookup_from, "lookup_field": node.lookup_field,
            "mmr": None if node.mmr is None else node.mmr.to_kernel(),
            "rank_constant": node.rank_constant,
            "weights": None if node.weights is None else list(node.weights),
        })
        return len(nodes) - 1

    visit(request, 0)
    return nodes
