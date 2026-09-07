"""Typed, dependency-free Python request and result values."""

from dataclasses import dataclass, field, fields, replace
from typing import Any, Literal, TypeAlias


Metric: TypeAlias = Literal["dot", "l2", "cosine"]
ScalarKind: TypeAlias = Literal["f32", "bf16", "f16", "i8"]
PayloadKind: TypeAlias = Literal["string", "int", "float", "bool"]
PayloadScalar: TypeAlias = str | int | float | bool


@dataclass(frozen=True, slots=True)
class CollectionConfig:
    """Friendly Python shape for the Mojo-owned durable collection identity."""

    dimension: int
    ann_metric: Metric = "l2"
    scalar_kind: ScalarKind = "f32"
    m: int = 16
    m0: int = 32
    ef_construction: int = 128
    default_ef_search: int = 64
    max_ef_search: int = 512
    max_level: int = 32
    rebuild_inactive_percent: int = 25
    delta_max_points: int = 10_000
    level_seed: int = 0xA5A5A5A5A5A5A5A5
    fingerprint: int | None = field(default=None, compare=False)

    def __post_init__(self) -> None:
        if not isinstance(self.dimension, int) or isinstance(self.dimension, bool):
            raise ValueError("collection dimension must be an integer")
        if self.dimension <= 0:
            raise ValueError("collection dimension must be positive")
        if self.ann_metric not in {"dot", "l2", "cosine"}:
            raise ValueError("unknown ann_metric")
        if self.scalar_kind not in {"f32", "bf16", "f16", "i8"}:
            raise ValueError("unknown scalar_kind")
        for name in (
            "m",
            "m0",
            "ef_construction",
            "default_ef_search",
            "max_ef_search",
            "max_level",
            "rebuild_inactive_percent",
            "delta_max_points",
            "level_seed",
        ):
            value = getattr(self, name)
            if not isinstance(value, int) or isinstance(value, bool):
                raise ValueError(f"collection {name} must be an integer")
        if self.level_seed < 0 or self.level_seed > 0xFFFF_FFFF_FFFF_FFFF:
            raise ValueError("collection level_seed must fit unsigned 64-bit")
        if self.fingerprint is not None and (
            not isinstance(self.fingerprint, int) or isinstance(self.fingerprint, bool)
        ):
            raise ValueError("collection fingerprint must be an integer")

    @classmethod
    def defaults(cls, dimension: int, **overrides: Any) -> "CollectionConfig":
        return replace(cls(dimension=dimension), **overrides)

    @classmethod
    def from_options(
        cls, dimension: int, value: "CollectionConfig | dict[str, Any] | None"
    ) -> "CollectionConfig":
        if value is None:
            return cls.defaults(dimension)
        if isinstance(value, cls):
            if value.dimension != dimension:
                raise ValueError("collection config dimension mismatch")
            return value
        if type(value) is not dict:
            raise ValueError("collection config must be a dict or CollectionConfig")
        options = dict(value)
        configured_dimension = options.pop("dimension", dimension)
        if type(configured_dimension) is not int:
            raise ValueError("collection dimension must be an integer")
        if configured_dimension != dimension:
            raise ValueError("collection config dimension mismatch")
        return cls.defaults(dimension, **options)

    @classmethod
    def from_kernel(cls, value: dict[str, Any]) -> "CollectionConfig":
        return cls(
            dimension=value["dimension"],
            ann_metric=value["ann_metric"],  # type: ignore[arg-type]
            scalar_kind=value["scalar_kind"],  # type: ignore[arg-type]
            m=value["m"],
            m0=value["m0"],
            ef_construction=value["ef_construction"],
            default_ef_search=value["default_ef_search"],
            max_ef_search=value["max_ef_search"],
            max_level=value["max_level"],
            rebuild_inactive_percent=value["rebuild_inactive_percent"],
            delta_max_points=value["delta_max_points"],
            level_seed=value["level_seed"],
            fingerprint=value["fingerprint"],
        )

    def to_kernel(self) -> dict[str, object]:
        # Mojo's CPython integer conversion currently enters through signed
        # Int64. Preserve all 64 seed bits across that boundary.
        kernel_seed = self.level_seed
        if kernel_seed > 0x7FFF_FFFF_FFFF_FFFF:
            kernel_seed -= 1 << 64
        return {
            "dimension": self.dimension,
            "ann_metric": self.ann_metric,
            "scalar_kind": self.scalar_kind,
            "m": self.m,
            "m0": self.m0,
            "ef_construction": self.ef_construction,
            "default_ef_search": self.default_ef_search,
            "max_ef_search": self.max_ef_search,
            "max_level": self.max_level,
            "rebuild_inactive_percent": self.rebuild_inactive_percent,
            "delta_max_points": self.delta_max_points,
            "level_seed": kernel_seed,
        }


@dataclass(frozen=True, slots=True)
class SearchStats:
    planner_reason: str
    backend_name: str
    metric_name: str
    scalar_name: str
    storage_name: str
    fallback_reason: str
    requested_ef: int
    effective_ef: int
    widening_rounds: int
    upper_visited: int
    base_visited: int
    visited: int
    distance_evaluations: int
    retained_candidates: int
    reranked_candidates: int
    filtered_rejections: int
    inactive_rejections: int
    base_candidates: int
    delta_candidates: int

    @classmethod
    def from_kernel(cls, value: dict[str, Any]) -> "SearchStats":
        return cls(**{field.name: value[field.name] for field in fields(cls)})


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
