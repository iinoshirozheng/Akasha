"""Arrow adapters with separate copying and C Data ownership paths."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from .database import Collection
from .models import PayloadField, SearchResult


@dataclass(slots=True)
class ArrowBatchLease:
    """One consumer ownership lease imported through Arrow C Data capsules."""

    _batch: Any | None
    _released: bool = False

    @classmethod
    def from_producer(cls, producer: Any) -> "ArrowBatchLease":
        try:
            import pyarrow as pa
        except ImportError as error:  # pragma: no cover
            raise RuntimeError("pyarrow is required for Arrow C Data import") from error
        if not hasattr(producer, "__arrow_c_array__"):
            raise TypeError("producer does not implement Arrow C Data protocol")
        schema_capsule, array_capsule = producer.__arrow_c_array__()
        batch = pa.RecordBatch._import_from_c_capsule(schema_capsule, array_capsule)
        return cls(batch)

    @property
    def released(self) -> bool:
        return self._released

    @property
    def batch(self) -> Any:
        if self._released or self._batch is None:
            raise RuntimeError("Arrow batch lease has been released")
        return self._batch

    def release(self) -> None:
        if self._released:
            raise RuntimeError("Arrow batch lease must be released exactly once")
        self._batch = None
        self._released = True

    def __enter__(self) -> "ArrowBatchLease":
        _ = self.batch
        return self

    def __exit__(self, *_: object) -> None:
        self.release()


def upsert_record_batch(
    collection: Collection, producer: Any | ArrowBatchLease
) -> int:
    """Synchronously ingest Arrow buffers without Python list materialization.

    Accepted values are necessarily copied into Akasha's WAL/MemTable ownership
    domain. The Arrow producer remains alive for the complete kernel call; its
    buffers must not be mutated or resized until this synchronous call returns.
    """

    owns_lease = not isinstance(producer, ArrowBatchLease)
    lease = ArrowBatchLease.from_producer(producer) if owns_lease else producer
    try:
        descriptor = _validated_descriptor(collection, lease.batch)
        return int(collection._call("apply_arrow_batch", descriptor))
    finally:
        if owns_lease:
            lease.release()


def results_to_record_batch(results: Sequence[SearchResult]) -> Any:
    """Export an independently owned Arrow result batch."""
    import pyarrow as pa

    return pa.record_batch(
        [
            pa.array((int(result.id) for result in results), type=pa.int64()),
            pa.array((float(result.score) for result in results), type=pa.float32()),
        ],
        names=["id", "score"],
    )


def _validated_descriptor(collection: Collection, batch: Any) -> dict[str, Any]:
    import numpy as np
    import pyarrow as pa

    if not isinstance(batch, pa.RecordBatch):
        raise TypeError("Arrow producer must yield one RecordBatch")
    batch.validate(full=True)
    if batch.num_rows <= 0:
        raise ValueError("Arrow record batch cannot be empty")
    names = batch.schema.names
    if len(set(names)) != len(names):
        raise ValueError("Arrow column names must be unique")
    if "id" not in names or "vector" not in names:
        raise ValueError("Arrow batch requires id and vector columns")
    allowed = {"id", "vector", "sparse_term_ids", "sparse_weights"}
    unknown = [
        name
        for name in names
        if name not in allowed and not name.startswith("payload.")
    ]
    if unknown:
        raise ValueError(f"unknown Arrow columns: {unknown}")

    ids = batch.column("id")
    vectors = batch.column("vector")
    if ids.type != pa.int64() or ids.null_count:
        raise ValueError("id must be non-null int64")
    expected_vector = pa.list_(pa.float32(), collection.dimension)
    if (
        vectors.type != expected_vector
        or vectors.null_count
        or vectors.values.null_count
    ):
        raise ValueError(
            "vector must be non-null fixed-size float32 list matching collection dimension"
        )

    id_view = _primitive_view(ids, 0, batch.num_rows)
    vector_view = _primitive_view(
        vectors.values, vectors.offset * collection.dimension,
        batch.num_rows * collection.dimension,
    )

    has_terms = "sparse_term_ids" in names
    has_weights = "sparse_weights" in names
    if has_terms != has_weights:
        raise ValueError("sparse term and weight columns must appear together")
    sparse_offsets = np.empty(0, dtype=np.int32)
    sparse_terms = np.empty(0, dtype=np.int64)
    sparse_weights = np.empty(0, dtype=np.float32)
    if has_terms:
        terms = batch.column("sparse_term_ids")
        weights = batch.column("sparse_weights")
        if terms.type != pa.list_(pa.int64()) or weights.type != pa.list_(pa.float32()):
            raise ValueError("sparse columns must be list<int64> and list<float32>")
        if (
            terms.null_count
            or weights.null_count
            or terms.values.null_count
            or weights.values.null_count
        ):
            raise ValueError("sparse columns cannot contain nulls")
        term_offsets = terms.offsets
        weight_offsets = weights.offsets
        if not term_offsets.equals(weight_offsets):
            raise ValueError("sparse term and weight offsets must match")
        sparse_offsets = _primitive_view(term_offsets, 0, batch.num_rows + 1)
        # Arrow list offsets index the logical child array. Child slicing is
        # already applied by to_numpy; do not subtract the child's offset.
        sparse_terms = _primitive_view(terms.values, 0, len(terms.values))
        sparse_weights = _primitive_view(weights.values, 0, len(weights.values))
        if (
            len(sparse_terms) != len(sparse_weights)
            or sparse_offsets[0] < 0
            or sparse_offsets[-1] > len(sparse_terms)
            or np.any(sparse_offsets[1:] <= sparse_offsets[:-1])
        ):
            raise ValueError("sparse offsets must identify non-empty bounded rows")
        begin, end = int(sparse_offsets[0]), int(sparse_offsets[-1])
        active_terms = sparse_terms[begin:end]
        active_weights = sparse_weights[begin:end]
        invalid_order = active_terms[1:] <= active_terms[:-1]
        # Adjacent values in different rows need not be ascending.
        invalid_order[sparse_offsets[1:-1] - begin - 1] = False
        if np.any(active_terms < 0) or np.any(invalid_order):
            raise ValueError("sparse term IDs must be non-negative and ascending")
        if not np.all(np.isfinite(active_weights)) or np.any(active_weights == 0.0):
            raise ValueError("sparse weights must be finite and non-zero")

    payloads: list[dict[str, Any]] = []
    type_names = {
        pa.string(): "string",
        pa.int64(): "int",
        pa.float64(): "float",
        pa.bool_(): "bool",
    }
    for name in names:
        if not name.startswith("payload."):
            continue
        field_name = name.removeprefix("payload.")
        if not field_name or "\x00" in field_name:
            raise ValueError("payload field name is invalid")
        array = batch.column(name)
        kind = type_names.get(array.type)
        if kind is None:
            raise ValueError(f"unsupported payload Arrow type for {name}: {array.type}")
        payloads.append({"name": field_name, "type": kind, "values": array})

    return {
        "row_count": batch.num_rows,
        "ids": id_view,
        "vectors": vector_view,
        "has_sparse": has_terms,
        "sparse_offsets": sparse_offsets,
        "sparse_terms": sparse_terms,
        "sparse_weights": sparse_weights,
        "payloads": payloads,
        "owners": batch,
    }


def _primitive_view(array: Any, start: int, count: int) -> Any:
    """Borrow an Arrow numeric slice; retain its owner through NumPy.base."""
    if start < 0 or count < 0 or start + count > len(array):
        raise ValueError("Arrow primitive buffer bounds are invalid")
    return array.slice(start, count).to_numpy(zero_copy_only=True, writable=False)


# Compatibility copying helpers. Their names deliberately do not claim C Data
# or zero-copy behavior.
def upsert_columns(collection: Collection, columns: Mapping[str, Any]) -> int:
    """Validate and copy an ID/vector/payload column batch into Mojo."""
    if "id" not in columns or "vector" not in columns:
        raise ValueError("column batch requires id and vector columns")
    ids = _to_list(columns["id"])
    vectors = _to_list(columns["vector"])
    payloads = _to_list(columns.get("fields", [None] * len(ids)))
    if len(ids) != len(vectors) or len(ids) != len(payloads):
        raise ValueError("Arrow-compatible columns must have equal lengths")
    for id_value, vector_value, payload_value in zip(ids, vectors, payloads):
        fields = None
        if payload_value is not None:
            fields = [PayloadField(**dict(item)) for item in payload_value]
        collection.upsert(
            int(id_value), [float(value) for value in vector_value], fields
        )
    return len(ids)


def results_to_columns(results: Sequence[SearchResult]) -> dict[str, list[Any]]:
    """Return fresh copying Arrow-compatible primitive columns."""
    return {
        "id": [int(result.id) for result in results],
        "score": [float(result.score) for result in results],
    }


def _to_list(value: Any) -> list[Any]:
    if hasattr(value, "to_pylist"):
        return list(value.to_pylist())
    if hasattr(value, "tolist"):
        return list(value.tolist())
    return list(value)
