"""Arrow adapters with separate copying and C Data ownership paths."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from .vectors import FieldQuery, IvfOptions
from .database import CancellationToken, Collection
from .exceptions import ValidationError, map_kernel_error
from .models import BatchWriteResult, PayloadField, SearchRequest, SearchResult


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


def upsert_point_record_batch(
    collection: Collection, producer: Any | ArrowBatchLease
) -> BatchWriteResult:
    """Commit native vector and payload columns in one atomic WAL batch.

    Columns: id, optional vector/sparse, vectors.<name>, payload.<name>.
    Omitted vectors remain unchanged, null vectors are removed, and empty
    sparse/multivector values stay present. Payload columns replace the payload;
    without payload columns it is preserved. Input buffers are borrowed for this
    synchronous call and copied into native authority before returning.
    """
    from .arrow_points import point_descriptor

    owns_lease = not isinstance(producer, ArrowBatchLease)
    lease = ArrowBatchLease.from_producer(producer) if owns_lease else producer
    try:
        descriptor = point_descriptor(collection, lease.batch)
        return BatchWriteResult(**collection._call("apply_point_arrow_batch", descriptor))
    finally:
        if owns_lease:
            lease.release()


def search_record_batch(collection: Collection, request: SearchRequest) -> Any:
    """Search directly into owned I64/F32 columns, without Python result rows.

    The native result list is columnized once (12 bytes per result). PyArrow
    retains those NumPy buffers; the batch and its slices outlive the collection.
    """
    import pyarrow as pa

    columns = collection._search_raw(request, columns=True)
    return pa.record_batch(
        [
            pa.array(columns["ids"], type=pa.int64(), from_pandas=False),
            pa.array(columns["scores"], type=pa.float32(), from_pandas=False),
        ],
        names=["id", "score"],
    )


def search_field_record_batch(
    collection: Collection, name: str, vector: Any, k: int,
    *, filter: Mapping[str, Any] | None = None,
    mode: str = "exact", ef_search: int | None = None, rerank_k: int = 0,
    ivf: IvfOptions | None = None,
    cancellation: CancellationToken | None = None, timeout_ns: int | None = None,
) -> Any:
    """Search one named field into owned Int64 IDs and Float64 scores."""
    import pyarrow as pa
    columns = collection._search_field_raw(name, vector, k, filter=filter, mode=mode,
                                           ef_search=ef_search, rerank_k=rerank_k, ivf=ivf, columns=True,
                                           cancellation=cancellation, timeout_ns=timeout_ns)
    return pa.record_batch([
        pa.array(columns["ids"], type=pa.int64(), from_pandas=False),
        pa.array(columns["scores"], type=pa.float64(), from_pandas=False),
    ], names=["id", "score"])


def search_fields_record_batch(
    collection: Collection, queries: list["FieldQuery"], k: int, *,
    fetch_k: int = 100, rank_constant: int = 60,
    filter: Mapping[str, Any] | None = None,
    rerank: "FieldQuery | None" = None,
    cancellation: CancellationToken | None = None, timeout_ns: int | None = None,
) -> Any:
    """Fuse field rankings from one read view into owned Float64 Arrow scores."""
    import pyarrow as pa
    columns = collection._search_fields_raw(
        queries, k, fetch_k=fetch_k, rank_constant=rank_constant, filter=filter, rerank=rerank,
        cancellation=cancellation, timeout_ns=timeout_ns, columns=True,
    )
    return pa.record_batch([
        pa.array(columns["ids"], type=pa.int64(), from_pandas=False),
        pa.array(columns["scores"], type=pa.float64(), from_pandas=False),
    ], names=["id", "score"])


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


class ArrowScanner:
    """Single-consumer iterator over a captured immutable collection view.

    Close explicitly (or use a context manager) when stopping early. Batches and
    slices own their buffers independently and remain valid after close. Output
    follows physical run/slot order, not global point-ID order. Python cancellation
    is checked between batches; native deadlines are checked during scanning.
    """

    def __init__(self, native: Any, cancellation: CancellationToken | None) -> None:
        self._native = native
        self._cancellation = cancellation
        self.schema = native.schema()
        self.closed = False
        self._exhausted = False
        self._stats = dict(rows=0, batches=0, materialized_bytes=0, borrowed_bytes=0, visited_slots=0)

    @property
    def stats(self) -> dict[str, int]:
        """Cumulative returned rows and logical output bytes (excluding padding).

        Materialized bytes include offsets/validity and gathered primitive data;
        borrowed bytes retain generation-owned buffers. Neither is peak RSS.
        """
        return self._stats.copy()

    def __iter__(self) -> ArrowScanner:
        return self

    def __next__(self) -> Any:
        if self.closed:
            raise RuntimeError("scanner is closed")
        if self._exhausted:
            raise StopIteration
        try:
            result = self._native.next_batch(
                self._cancellation is not None and self._cancellation.cancelled
            )
        except Exception as error:
            self.close()
            raise map_kernel_error(error) from error
        self._stats["visited_slots"] = result["visited_slots"]
        if result["batch"] is None:
            self._exhausted = True
            self._native.close()
            raise StopIteration
        batch = result["batch"]
        self._stats["rows"] += batch.num_rows
        self._stats["batches"] += 1
        for name in ("materialized_bytes", "borrowed_bytes"):
            self._stats[name] += result[name]
        return batch

    def close(self) -> None:
        if not self.closed:
            self._native.close()
            self.closed = True

    def __enter__(self) -> ArrowScanner:
        if self.closed:
            raise RuntimeError("scanner is closed")
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def scan_record_batches(
    collection: Collection,
    *,
    batch_size: int = 1024,
    columns: Sequence[str] = ("id", "vector", "sparse_term_ids", "sparse_weights"),
    vectors: Sequence[str] = (),
    payload_schema: Mapping[str, str] | None = None,
    filter: Mapping[str, Any] | None = None,
    cancellation: CancellationToken | None = None,
    max_candidates: int | None = None,
    deadline_ns: int = 0,
    max_batch_bytes: int = 64 * 1024 * 1024,
) -> ArrowScanner:
    """Capture a snapshot and export bounded batches through native Arrow C Data.

    Core projections accept id, sequence, vector, sparse_term_ids, sparse_weights.
    Payload projections map names to string/int/float/bool; absent values are null,
    present values of a different type fail the scan. Sparse absence is null;
    present sparse vectors retain their ragged lengths. No Python row staging is used.

    One-row dense buffers are borrowed; multi-row vectors and other columns are
    gathered into final owned buffers. The byte cap bounds aligned output buffer
    allocations per batch; a batch exceeding it fails and closes the scanner.
    It excludes source generations, selection descriptors and Arrow metadata.
    """
    if max_candidates is None:
        max_candidates = collection.limits.max_candidates
    for name, value in (("batch_size", batch_size), ("max_candidates", max_candidates),
                        ("max_batch_bytes", max_batch_bytes)):
        if type(value) is not int or value <= 0 or value > (1 << 63) - 1:
            raise ValueError(f"{name} must be a positive signed 64-bit integer")
    if batch_size > max_batch_bytes // 8:
        raise ValueError("batch_size selection exceeds max_batch_bytes")
    if type(deadline_ns) is not int or not 0 <= deadline_ns <= (1 << 63) - 1:
        raise ValueError("deadline_ns must be a nonnegative signed 64-bit integer")
    if isinstance(columns, (str, bytes)):
        raise TypeError("columns must be a sequence of column names")
    kinds = {"id": 1, "sequence": 2, "vector": 3, "sparse_term_ids": 4, "sparse_weights": 5, "document_sequence": 11}
    descriptors = []
    for name in columns:
        if not isinstance(name, str) or name not in kinds:
            raise ValueError(f"unknown scanner column: {name!r}")
        descriptors.append(dict(name=name, kind=kinds[name], payload_name=""))
    if isinstance(vectors, (str, bytes)):
        raise TypeError("vectors must be a sequence of field names")
    for name in vectors:
        if not isinstance(name, str) or not name or "\0" in name:
            raise ValueError("vector names must be nonempty strings without NUL")
        descriptors.append(dict(name=f"vectors.{name}", kind=10, payload_name=name))
    payload_kinds = {"string": 6, "int": 7, "float": 8, "bool": 9}
    for name, kind in (payload_schema or {}).items():
        if not isinstance(name, str) or not name or "\0" in name:
            raise ValueError("payload names must be nonempty strings without NUL")
        if not isinstance(kind, str) or kind not in payload_kinds:
            raise ValueError(f"unsupported scanner payload type: {kind!r}")
        descriptors.append(dict(name=f"payload.{name}", kind=payload_kinds[kind], payload_name=name))
    if len({item["name"] for item in descriptors}) != len(descriptors):
        raise ValueError("scanner column names must be unique")
    options = dict(batch_size=batch_size, columns=descriptors,
                   filter=None if filter is None else dict(filter),
                   max_candidates=max_candidates, deadline_ns=deadline_ns,
                   max_batch_bytes=max_batch_bytes)
    return ArrowScanner(collection._call("scanner", options), cancellation)


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
