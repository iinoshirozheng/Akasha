"""Typed, dependency-free Python request and result values."""

from dataclasses import dataclass, field
from typing import Literal, TypeAlias


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
class SearchRequest:
    metric: Metric
    k: int
    vector: list[float] | None = None
    sparse: list[SparseElement] = field(default_factory=list)
    mode: Literal["exact", "approx", "sparse", "hybrid"] = "exact"
    ef_search: int = 64
    fetch_k: int = 50
    rank_constant: int = 60
