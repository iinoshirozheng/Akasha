"""Typed, dependency-free Python request and result values."""

from dataclasses import dataclass, field
from typing import Any, Literal, TypeAlias


Metric: TypeAlias = Literal["dot", "l2", "cosine"]
PayloadKind: TypeAlias = Literal["string", "int", "float", "bool"]
PayloadScalar: TypeAlias = str | int | float | bool


@dataclass(frozen=True, slots=True)
class PayloadField:
    name: str
    type: PayloadKind
    value: PayloadScalar

    def to_kernel(self) -> dict[str, object]:
        return {"name": self.name, "type": self.type, "value": self.value}


@dataclass(frozen=True, slots=True)
class SparseElement:
    term_id: int
    weight: float

    def to_kernel(self) -> dict[str, object]:
        return {"term_id": self.term_id, "weight": self.weight}


@dataclass(frozen=True, slots=True)
class SearchResult:
    id: int
    score: float


@dataclass(frozen=True, slots=True)
class Document:
    id: int
    sequence: int
    vector: list[float]
    fields: list[PayloadField] = field(default_factory=list)


@dataclass(frozen=True, slots=True)
class Projection:
    """Select vector and payload fields returned by a projected point read."""

    include_vector: bool = True
    fields: tuple[str, ...] | None = None

    def to_kernel(self) -> dict[str, object]:
        if self.fields is not None:
            if any(not name for name in self.fields):
                raise ValueError("projection field name cannot be empty")
            if len(set(self.fields)) != len(self.fields):
                raise ValueError("projection field names must be unique")
        return {
            "include_vector": self.include_vector,
            "all_fields": self.fields is None,
            "fields": [] if self.fields is None else list(self.fields),
        }


@dataclass(frozen=True, slots=True)
class BatchMutation:
    operation: Literal["upsert", "delete"]
    id: int
    vector: list[float] | None = None
    fields: list[PayloadField] = field(default_factory=list)

    @classmethod
    def upsert(
        cls,
        id: int,
        vector: list[float],
        fields: list[PayloadField] | None = None,
    ) -> "BatchMutation":
        return cls("upsert", id, vector, [] if fields is None else fields)

    @classmethod
    def delete(cls, id: int) -> "BatchMutation":
        return cls("delete", id)

    def to_kernel(self) -> dict[str, object]:
        return {
            "operation": self.operation,
            "id": self.id,
            "vector": [] if self.vector is None else self.vector,
            "fields": [item.to_kernel() for item in self.fields],
        }


@dataclass(frozen=True, slots=True)
class BatchWriteResult:
    first_sequence: int
    last_sequence: int
    count: int


@dataclass(frozen=True, slots=True)
class SearchRequest:
    metric: Metric
    k: int
    vector: list[float] | None = None
    sparse: list[SparseElement] = field(default_factory=list)
    mode: Literal["exact", "approx", "sparse", "hybrid"] = "exact"
    ef_search: int = 64
    fetch_k: int = 50
    rank_constant: int = 60
    filter: dict[str, Any] | None = None


@dataclass(frozen=True, slots=True)
class ResourceLimits:
    max_batch_rows: int = 65_536
    max_query_batch: int = 1_024
    max_k: int = 10_000
    max_candidates: int = 10_000_000

    def __post_init__(self) -> None:
        if min(
            self.max_batch_rows,
            self.max_query_batch,
            self.max_k,
            self.max_candidates,
        ) <= 0:
            raise ValueError("resource limits must be positive")


@dataclass(frozen=True, slots=True)
class MetricsSnapshot:
    operations: int
    writes: int
    queries: int
    failures: int
    cancellations: int
    total_duration_ns: int


@dataclass(frozen=True, slots=True)
class TraceRecord:
    operation: str
    duration_ns: int
    status: Literal["ok", "error"]
    sequence: int | None
