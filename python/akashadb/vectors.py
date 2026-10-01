"""Field schemas and atomic point requests for native vector authority."""

from dataclasses import dataclass, field
from typing import Any, Literal

from .models import CollectionConfig, PayloadField, SparseElement

VectorDType = Literal["f32", "bf16", "f16", "i8", "u8", "binary"]
VectorKind = Literal["dense", "sparse", "multivector", "binary"]
VectorMetric = Literal["dot", "l2", "cosine", "hamming", "jaccard"]


@dataclass(frozen=True, slots=True)
class VectorField:
    dimension: int
    dtype: VectorDType = "f32"
    kind: VectorKind = "dense"
    metric: VectorMetric = "l2"
    hnsw: CollectionConfig | None = None

    def __post_init__(self) -> None:
        if type(self.dimension) is not int or not 0 <= self.dimension <= 0xFFFF_FFFF:
            raise ValueError("vector dimension must fit UInt32")
        if self.dtype not in {"f32", "bf16", "f16", "i8", "u8", "binary"}:
            raise ValueError("unknown vector dtype")
        if self.kind in {"dense", "multivector"}:
            if not self.dimension or self.dtype == "binary" or self.metric not in {"dot", "l2", "cosine"}:
                raise ValueError("invalid numeric vector schema")
        elif self.kind == "sparse":
            if self.dimension != 0 or self.dtype != "f32" or self.metric != "dot":
                raise ValueError("sparse fields require dimension 0, f32 and dot")
        elif self.kind == "binary":
            if not self.dimension or self.dtype != "binary" or self.metric not in {"hamming", "jaccard"}:
                raise ValueError("invalid packed binary schema")
        else:
            raise ValueError("unknown vector kind")
        if self.hnsw is not None and (
            self.kind != "dense" or self.hnsw.dimension != self.dimension or self.hnsw.ann_metric != self.metric
        ):
            raise ValueError("HNSW configuration must match its dense field")

    def to_kernel(self, name: str, field_id: int) -> dict[str, Any]:
        if type(name) is not str or not name or "\x00" in name:
            raise ValueError("named vector fields require a nonempty name without NUL")
        return {
            "id": field_id, "name": name, "dimension": self.dimension,
            "dtype": self.dtype, "kind": self.kind, "metric": self.metric,
            "hnsw": None if self.hnsw is None else self.hnsw.to_kernel(),
        }

    @classmethod
    def from_kernel(cls, value: dict[str, Any]) -> "VectorField":
        hnsw = value["hnsw"]
        return cls(value["dimension"], value["dtype"], value["kind"], value["metric"],
                   None if hnsw is None else CollectionConfig.from_kernel(hnsw))


_UNSET = object()


def _vector_value(value: Any) -> Any:
    if isinstance(value, (list, tuple)) and value and isinstance(value[0], SparseElement):
        return [element.to_kernel() for element in value]
    return value


@dataclass(frozen=True, slots=True)
class IvfOptions:
    """Root-cached L2 coarse partitions; native scoring within selected lists."""

    nlist: int = 32
    nprobe: int = 4
    iterations: int = 8

    def __post_init__(self) -> None:
        if any(type(value) is not int for value in (self.nlist, self.nprobe, self.iterations)):
            raise ValueError("IVF parameters must be integers")
        if not 1 <= self.nlist <= 256 or not 1 <= self.nprobe <= self.nlist or self.iterations <= 0:
            raise ValueError("IVF requires 1..256 lists, 1..nlist probes and positive iterations")

    def to_kernel(self) -> dict[str, int]:
        return {"nlist": self.nlist, "nprobe": self.nprobe, "iterations": self.iterations}


@dataclass(frozen=True, slots=True)
class FieldQuery:
    """One independently ranked branch of a captured-root RRF query."""

    name: str
    vector: Any
    mode: Literal["exact", "approx", "ivf"] = "exact"
    ef_search: int | None = None
    rerank_k: int = 0
    ivf: IvfOptions | None = None

    def __post_init__(self) -> None:
        if type(self.name) is not str or not self.name or "\x00" in self.name:
            raise ValueError("field query requires a nonempty name without NUL")
        if self.mode not in ("exact", "approx", "ivf"):
            raise ValueError("field query mode must be exact, approx or ivf")
        if self.ef_search is not None and (type(self.ef_search) is not int or self.ef_search <= 0):
            raise ValueError("ef_search must be a positive integer")
        if type(self.rerank_k) is not int or self.rerank_k < 0:
            raise ValueError("rerank_k must be a nonnegative integer")
        if self.mode != "approx" and (self.ef_search is not None or self.rerank_k):
            raise ValueError("ef_search and rerank_k require approximate field search")
        if self.ivf is not None and (self.mode != "ivf" or not isinstance(self.ivf, IvfOptions)):
            raise ValueError("IvfOptions require ivf mode")

    def to_kernel(self) -> dict[str, Any]:
        return {"name": self.name, "vector": _vector_value(self.vector), "mode": self.mode,
                "ef_search": -1 if self.ef_search is None else self.ef_search,
                "rerank_k": self.rerank_k,
                "ivf": (self.ivf or IvfOptions()).to_kernel() if self.mode == "ivf" else None}


@dataclass(frozen=True, slots=True)
class PointMutation:
    """Omitted values stay; None removes a vector, [] preserves empty sparse/matrices."""

    operation: Literal["upsert", "update", "delete"]
    id: int
    vectors: dict[str, Any] = field(default_factory=dict)
    vector: Any = _UNSET
    sparse: Any = _UNSET
    fields: list[PayloadField] | None = None

    @classmethod
    def upsert(cls, id: int, *, vectors: dict[str, Any] | None = None,
               vector: Any = _UNSET, sparse: Any = _UNSET,
               fields: list[PayloadField] | None = None) -> "PointMutation":
        return cls("upsert", id, {} if vectors is None else vectors, vector, sparse, fields)

    @classmethod
    def update(cls, id: int, *, vectors: dict[str, Any] | None = None,
               vector: Any = _UNSET, sparse: Any = _UNSET,
               fields: list[PayloadField] | None = None) -> "PointMutation":
        return cls("update", id, {} if vectors is None else vectors, vector, sparse, fields)

    @classmethod
    def delete(cls, id: int) -> "PointMutation":
        return cls("delete", id)

    def to_kernel(self) -> dict[str, Any]:
        updates = []
        if self.vector is not _UNSET:
            updates.append({"id": 0, "value": self.vector})
        if self.sparse is not _UNSET:
            updates.append({"id": 1, "value": _vector_value(self.sparse)})
        updates.extend({"name": name, "value": _vector_value(value)} for name, value in self.vectors.items())
        return {"operation": self.operation, "id": self.id, "updates": updates,
                "fields": None if self.fields is None else [item.to_kernel() for item in self.fields]}


@dataclass(frozen=True, slots=True)
class Point:
    id: int
    sequence: int
    document_sequence: int
    vector: list[float] | None
    sparse: list[SparseElement] | None
    vectors: dict[str, Any]
    fields: list[PayloadField]

    @classmethod
    def from_kernel(cls, value: dict[str, Any]) -> "Point":
        vectors = {
            name: [SparseElement(**item) for item in data]
            if isinstance(data, list) and data and isinstance(data[0], dict)
            else data
            for name, data in value["vectors"].items()
        }
        return cls(value["id"], value["sequence"], value["document_sequence"], value["vector"],
                   None if value["sparse"] is None else [SparseElement(**item) for item in value["sparse"]],
                   vectors, [PayloadField(**item) for item in value["fields"]])
