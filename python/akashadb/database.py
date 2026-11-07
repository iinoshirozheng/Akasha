"""In-process Python adapter over the compiled Mojo kernel extension."""

from pathlib import Path
from threading import Event
from time import monotonic_ns, perf_counter_ns
from typing import Any, Mapping, Protocol

from .vectors import ContextPair, FieldQuery, IvfOptions, MmrOptions, Point, PointMutation, VectorField, _vector_value
from .exceptions import CollectionNotFoundError, ValidationError, map_kernel_error
from .models import (
    BatchMutation,
    BatchWriteResult,
    CollectionConfig,
    Document,
    PayloadField,
    Projection,
    MetricsSnapshot,
    ResourceLimits,
    SearchRequest,
    SearchResult,
    SearchStats,
    SparseElement,
    TraceRecord,
)


class KernelCollection(Protocol):
    def create_json_index(self, name: str, column: str, path: str) -> None: ...
    def drop_json_index(self, name: str) -> None: ...
    def rebuild_json_index(self, name: str) -> None: ...
    def json_indexes(self) -> list[dict[str, Any]]: ...
    def query_json(self, expression: dict[str, Any], indexes: list[str],
                   options: dict[str, Any]) -> list[int]: ...
    def prepare_json(self, expression: dict[str, Any], indexes: list[str],
                     options: dict[str, Any]) -> Any: ...
    def close(self) -> None: ...
    def last_sequence(self) -> int: ...
    def collection_config(self) -> dict[str, Any]: ...
    def last_search_stats(self) -> dict[str, Any]: ...
    def vector_fields(self) -> list[dict[str, Any]]: ...
    def apply_point_batch(self, mutations: list[dict[str, Any]]) -> dict[str, int]: ...
    def apply_payload_update(self, options: dict[str, Any]) -> dict[str, int]: ...
    def get_point(self, id: int) -> dict[str, Any] | None: ...
    def search_field(
        self, name: str, vector: Any, k: int, options: dict[str, Any],
    ) -> list[dict[str, Any]]: ...
    def upsert(self, id: int, vector: list[float]) -> None: ...
    def upsert_document(
        self, id: int, vector: list[float], fields: list[dict[str, object]]
    ) -> None: ...
    def apply_batch(
        self, mutations: list[dict[str, object]]
    ) -> dict[str, int]: ...
    def upsert_sparse(self, id: int, elements: list[dict[str, object]]) -> None: ...
    def delete(self, id: int) -> None: ...
    def flush(self) -> None: ...
    def get(self, id: int) -> dict[str, Any] | None: ...
    def get_projected(
        self, id: int, projection: dict[str, object]
    ) -> dict[str, Any] | None: ...
    def apply_arrow_batch(self, descriptor: dict[str, object]) -> int: ...
    def search_dot(self, vector: list[float], k: int) -> list[dict[str, Any]]: ...
    def search_l2(self, vector: list[float], k: int) -> list[dict[str, Any]]: ...
    def search_cosine(self, vector: list[float], k: int) -> list[dict[str, Any]]: ...
    def search_batch(
        self,
        metric: str,
        vectors: list[list[float]],
        k: int,
        num_workers: int,
    ) -> list[list[dict[str, Any]]]: ...
    def search_batch_where(
        self,
        metric: str,
        vectors: list[list[float]],
        filters: list[dict[str, Any]],
        k: int,
        num_workers: int,
    ) -> list[list[dict[str, Any]]]: ...
    def search_approx(
        self, metric: str, vector: list[float], k: int, ef_search: int
    ) -> list[dict[str, Any]]: ...
    def search_sparse(
        self, sparse: list[dict[str, object]], k: int
    ) -> list[dict[str, Any]]: ...
    def search_hybrid(
        self,
        metric: str,
        vector: list[float],
        sparse: list[dict[str, object]],
        options: dict[str, int],
    ) -> list[dict[str, Any]]: ...
    def search_dense_where(
        self, metric: str, vector: list[float], options: dict[str, object]
    ) -> list[dict[str, Any]]: ...
    def search_sparse_where(
        self, sparse: list[dict[str, object]], options: dict[str, object]
    ) -> list[dict[str, Any]]: ...
    def search_hybrid_where(
        self,
        metric: str,
        vector: list[float],
        sparse: list[dict[str, object]],
        options: dict[str, object],
    ) -> list[dict[str, Any]]: ...
    def backup_to(self, target: str) -> dict[str, Any]: ...
    def export_records(self) -> list[dict[str, Any]]: ...
    def export_points(self) -> dict[str, Any] | None: ...
    def is_point_collection(self) -> bool: ...
    def scanner(self, options: dict[str, Any]) -> Any: ...
    def search_controlled(
        self,
        metric: str,
        vector: list[float],
        k: int,
        options: dict[str, object],
    ) -> list[dict[str, Any]]: ...


def _kernel_module() -> Any:
    from . import _kernel

    return _kernel


class Collection:
    """Typed Python facade whose state and operations live in Mojo."""

    def __init__(
        self,
        path: str | Path,
        dimension: int,
        *,
        config: CollectionConfig | dict[str, Any] | None = None,
        vectors: dict[str, VectorField] | None = None,
        kernel: KernelCollection | None = None,
        limits: ResourceLimits | None = None,
    ) -> None:
        try:
            requested = (
                None
                if config is None
                else CollectionConfig.from_options(dimension, config)
            )
            schema = None if vectors is None else [value.to_kernel(name, index + 2) for index, (name, value) in enumerate(sorted(vectors.items()))]
        except (TypeError, ValueError) as error:
            raise ValidationError(str(error)) from error
        try:
            self._kernel: KernelCollection = (
                kernel
                if kernel is not None
                else (
                    _kernel_module().Collection(str(path), dimension, None if requested is None else requested.to_kernel(), schema)
                    if schema is not None
                    else _kernel_module().Collection(str(path), dimension)
                    if requested is None
                    else _kernel_module().Collection(
                        str(path), dimension, requested.to_kernel()
                    )
                )
            )
        except Exception as error:
            raise map_kernel_error(error) from error
        self.path = Path(path)
        self.dimension = dimension
        self._config = CollectionConfig.from_kernel(self._kernel.collection_config())
        self.limits = limits or ResourceLimits()
        self._operations = 0
        self._writes = 0
        self._queries = 0
        self._failures = 0
        self._cancellations = 0
        self._total_duration_ns = 0
        self._traces: list[TraceRecord] = []

    def _call(self, method: str, *args: object) -> Any:
        started = perf_counter_ns()
        try:
            result = getattr(self._kernel, method)(*args)
        except Exception as error:
            duration = perf_counter_ns() - started
            self._record_operation(method, duration, "error", str(error))
            raise map_kernel_error(error) from error
        duration = perf_counter_ns() - started
        self._record_operation(method, duration, "ok", None)
        return result

    def create_json_index(self, name: str, column: str, path: str) -> None:
        """Persist a bitmap definition after native type inference and validation."""
        self._call("create_json_index", name, column, path)

    def json_indexes(self) -> list[dict[str, Any]]:
        """Return owned catalog definitions with fixed learned target types."""
        return self._call("json_indexes")

    def drop_json_index(self, name: str) -> None:
        self._call("drop_json_index", name)

    def rebuild_json_index(self, name: str) -> None:
        """Rebuild this captured root's bitmap while preserving its learned type."""
        self._call("rebuild_json_index", name)

    def query_json(self, expression: Mapping[str, Any], *, indexes: list[str] | None = None,
                   timeout_ns: int | None = None,
                   cancellation: "CancellationToken | None" = None) -> list[int]:
        """Execute a native nullable expression on one captured read snapshot."""
        options = _json_query_options(timeout_ns, cancellation)
        options["max_candidates"] = self.limits.max_candidates
        _validate_json_arguments(expression, indexes)
        return self._call("query_json", dict(expression), [] if indexes is None else indexes, options)

    def prepare_json(self, expression: Mapping[str, Any], *, indexes: list[str] | None = None,
                     timeout_ns: int | None = None,
                     cancellation: "CancellationToken | None" = None) -> "PreparedJsonQuery":
        """Capture an owned query snapshot, independent of this collection's lifetime."""
        options = _json_query_options(timeout_ns, cancellation)
        options["max_candidates"] = self.limits.max_candidates
        _validate_json_arguments(expression, indexes)
        return PreparedJsonQuery(self._call("prepare_json", dict(expression),
                                           [] if indexes is None else indexes, options))

    def _record_operation(
        self, method: str, duration_ns: int, status: str, error: str | None
    ) -> None:
        self._operations += 1
        self._total_duration_ns += duration_ns
        if method.startswith(("search", "get", "recommend", "discover", "query")):
            self._queries += 1
        if status == "ok" and method.startswith(("upsert", "delete", "apply")):
            self._writes += 1
        if status == "error":
            self._failures += 1
            if error is not None and "cancel" in error.lower():
                self._cancellations += 1
        sequence = None
        if status == "ok" and method.startswith(("upsert", "delete", "apply")):
            try:
                sequence = int(self._kernel.last_sequence())
            except Exception:
                sequence = None
        self._traces.append(
            TraceRecord(method, duration_ns, status, sequence)  # type: ignore[arg-type]
        )
        if len(self._traces) > 256:
            del self._traces[0]

    def metrics(self) -> MetricsSnapshot:
        return MetricsSnapshot(
            self._operations,
            self._writes,
            self._queries,
            self._failures,
            self._cancellations,
            self._total_duration_ns,
        )

    def traces(self) -> tuple[TraceRecord, ...]:
        return tuple(self._traces)

    def close(self) -> None:
        self._call("close")

    @property
    def last_sequence(self) -> int:
        return int(self._call("last_sequence"))

    def collection_config(self) -> CollectionConfig:
        return CollectionConfig.from_kernel(dict(self._call("collection_config")))

    def last_search_stats(self) -> SearchStats:
        return SearchStats.from_kernel(dict(self._call("last_search_stats")))

    def upsert(
        self,
        id: int,
        vector: list[float],
        fields: list[PayloadField] | None = None,
    ) -> None:
        if fields is None:
            self._call("upsert", id, vector)
        else:
            self._call(
                "upsert_document", id, vector, [item.to_kernel() for item in fields]
            )

    def vector_fields(self) -> dict[str, VectorField]:
        return {item["name"]: VectorField.from_kernel(item) for item in self._call("vector_fields") if item["id"] >= 2}

    def apply_point_batch(self, mutations: list[PointMutation]) -> BatchWriteResult:
        if len(mutations) > self.limits.max_batch_rows:
            raise ValidationError("mutation batch resource limit exceeded")
        raw = self._call("apply_point_batch", [item.to_kernel() for item in mutations])
        return BatchWriteResult(**raw)

    def set_payload(self, payload: dict[str, Any], *, points: list[int] | None = None,
                    filter: Mapping[str, Any] | None = None, key: str | None = None) -> BatchWriteResult:
        """Merge payload at the root or a JSON path on existing selected points."""
        return self._payload_update("set", payload, points=points, filter=filter, key=key)

    def overwrite_payload(self, payload: dict[str, Any], *, points: list[int] | None = None,
                          filter: Mapping[str, Any] | None = None) -> BatchWriteResult:
        """Replace the complete payload while retaining every vector field."""
        return self._payload_update("overwrite", payload, points=points, filter=filter)

    def delete_payload(self, keys: list[str], *, points: list[int] | None = None,
                       filter: Mapping[str, Any] | None = None) -> BatchWriteResult:
        """Remove JSON paths, in order, from existing selected points."""
        return self._payload_update("delete", None, points=points, filter=filter, keys=keys)

    def clear_payload(self, *, points: list[int] | None = None,
                      filter: Mapping[str, Any] | None = None) -> BatchWriteResult:
        """Remove all payload fields while retaining the points and vectors."""
        return self._payload_update("clear", None, points=points, filter=filter)

    def _payload_update(self, operation: str, payload: dict[str, Any] | None, *,
                        points: list[int] | None, filter: Mapping[str, Any] | None,
                        key: str | None = None, keys: list[str] | None = None) -> BatchWriteResult:
        raw = self._call("apply_payload_update", {
            "operation": operation, "payload": payload, "points": points, "filter": filter,
            "key": key, "keys": [] if keys is None else keys,
            "max_points": min(self.limits.max_batch_rows, 65_536),
        })
        return BatchWriteResult(**raw)

    def get_point(self, id: int) -> Point | None:
        raw = self._call("get_point", id)
        return None if raw is None else Point.from_kernel(raw)

    def search_field(
        self, name: str, vector: Any, k: int, *,
        filter: Mapping[str, Any] | None = None, mode: str = "exact",
        ef_search: int | None = None, rerank_k: int = 0,
        ivf: IvfOptions | None = None, mmr: MmrOptions | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> list[SearchResult]:
        raw = self._search_field_raw(name, vector, k, filter=filter, mode=mode,
                                     ef_search=ef_search, rerank_k=rerank_k, ivf=ivf, mmr=mmr,
                                     cancellation=cancellation, timeout_ns=timeout_ns)
        return [SearchResult(**item) for item in raw]

    def query(
        self, request: "QueryRequest", *, cancellation: "CancellationToken | None" = None,
        timeout_ns: int | None = None,
    ) -> list[SearchResult]:
        """Execute an ordered query tree on one captured native read view."""
        return [SearchResult(**item) for item in self._query_raw(
            request, cancellation=cancellation, timeout_ns=timeout_ns)]

    def _query_raw(
        self, request: "QueryRequest", *, columns: bool = False,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> Any:
        from .query import serialize_query
        if timeout_ns is not None and (type(timeout_ns) is not int or timeout_ns <= 0):
            raise ValidationError("query timeout must be a positive integer")
        deadline = 0 if timeout_ns is None else monotonic_ns() + timeout_ns
        nodes = serialize_query(request, self.limits.max_query_batch, self.limits.max_query_batch)
        for node in nodes:
            lookup = node["lookup_from"]
            if lookup is not None and not isinstance(lookup, Collection):
                raise ValidationError("lookup_from must be an open Collection")
            node["lookup_from"] = None if lookup is None else lookup._kernel
        return self._call("query_columns" if columns else "query", nodes, {
            "max_nodes": self.limits.max_query_batch, "max_examples": self.limits.max_query_batch,
            "max_k": self.limits.max_k, "max_candidates": self.limits.max_candidates,
            "deadline_ns": deadline, "cancelled": bool(cancellation and cancellation.cancelled),
        })

    def discover_field(
        self, name: str, target: Any = None, context: list[ContextPair] | None = None,
        k: int = 10, *, mode: str = "exact", ef_search: int | None = None,
        lookup_from: "Collection | None" = None, lookup_field: str | None = None,
        filter: Mapping[str, Any] | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> list[SearchResult]:
        """Discover using a target and/or positive/negative context pairs."""
        raw = self._discover_field_raw(
            name, target, context, k, mode=mode, ef_search=ef_search,
            lookup_from=lookup_from, lookup_field=lookup_field, filter=filter,
            cancellation=cancellation, timeout_ns=timeout_ns,
        )
        return [SearchResult(**item) for item in raw]

    def _discover_field_raw(
        self, name: str, target: Any = None, context: list[ContextPair] | None = None,
        k: int = 10, *, mode: str = "exact", ef_search: int | None = None,
        lookup_from: "Collection | None" = None, lookup_field: str | None = None,
        filter: Mapping[str, Any] | None = None, columns: bool = False,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> Any:
        if type(k) is not int or not 0 <= k <= self.limits.max_k:
            raise ValidationError("discovery k exceeds resource limit")
        method = "discover_field_columns" if columns else "discover_field"
        if k == 0:
            # Match Qdrant's single-query early return; still check open target
            # and record the native result/stats through the normal boundary.
            return self._call(method, name, None, [], 0, {})
        if context is not None and not isinstance(context, (list, tuple)):
            raise ValidationError("context must be a list of ContextPair values")
        context = [] if context is None else context
        if 2 * len(context) + (target is not None) > self.limits.max_query_batch:
            raise ValidationError("discovery example resource limit exceeded")
        if any(not isinstance(pair, ContextPair) for pair in context):
            raise ValidationError("context must contain ContextPair values")
        if mode not in ("exact", "approx"):
            raise ValidationError("discovery mode must be exact or approx")
        if ef_search is not None and (type(ef_search) is not int or ef_search <= 0 or mode != "approx"):
            raise ValidationError("ef_search must be positive and requires approximate discovery")
        if lookup_from is not None and not isinstance(lookup_from, Collection):
            raise ValidationError("lookup_from must be an open Collection")
        if lookup_field is not None and (type(lookup_field) is not str or not lookup_field):
            raise ValidationError("lookup_field must be a nonempty field name")
        if timeout_ns is not None and (type(timeout_ns) is not int or timeout_ns <= 0):
            raise ValidationError("query timeout must be a positive integer")
        deadline = 0 if timeout_ns is None else monotonic_ns() + timeout_ns
        return self._call(method, name, _vector_value(target), [pair.to_kernel() for pair in context], k,
            {"mode": mode, "ef_search": -1 if ef_search is None else ef_search,
             "max_examples": self.limits.max_query_batch,
             "lookup_from": None if lookup_from is None else lookup_from._kernel,
             "lookup_field": lookup_field, "filter": None if filter is None else dict(filter),
             "cancelled": bool(cancellation and cancellation.cancelled),
             "deadline_ns": deadline, "max_candidates": self.limits.max_candidates})

    def recommend_field(
        self, name: str, positive: list[Any], negative: list[Any] | None = None,
        k: int = 10, *, strategy: str = "average_vector", mode: str = "exact",
        ef_search: int | None = None,
        lookup_from: "Collection | None" = None, lookup_field: str | None = None,
        filter: Mapping[str, Any] | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> list[SearchResult]:
        """Recommend from raw vectors and/or IDs using Qdrant's F32 scoring rules."""
        raw = self._recommend_field_raw(
            name, positive, negative, k, strategy=strategy, mode=mode, ef_search=ef_search,
            lookup_from=lookup_from, lookup_field=lookup_field, filter=filter,
            cancellation=cancellation, timeout_ns=timeout_ns,
        )
        return [SearchResult(**item) for item in raw]

    def _recommend_field_raw(
        self, name: str, positive: list[Any], negative: list[Any] | None = None,
        k: int = 10, *, strategy: str = "average_vector", mode: str = "exact",
        ef_search: int | None = None,
        lookup_from: "Collection | None" = None, lookup_field: str | None = None,
        filter: Mapping[str, Any] | None = None, columns: bool = False,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> Any:
        if not isinstance(positive, (list, tuple)) or (negative is not None and not isinstance(negative, (list, tuple))):
            raise ValidationError("recommendation examples must be lists")
        negative = [] if negative is None else negative
        if len(positive) + len(negative) > self.limits.max_query_batch:
            raise ValidationError("recommendation example resource limit exceeded")
        if type(k) is not int or not 0 < k <= self.limits.max_k:
            raise ValidationError("recommendation k exceeds resource limit")
        if strategy not in ("average_vector", "best_score", "sum_scores"):
            raise ValidationError("unknown recommendation strategy")
        if mode not in ("exact", "approx"):
            raise ValidationError("recommendation mode must be exact or approx")
        if ef_search is not None and (type(ef_search) is not int or ef_search <= 0 or mode != "approx"):
            raise ValidationError("ef_search must be positive and requires approximate recommendation")
        if lookup_from is not None and not isinstance(lookup_from, Collection):
            raise ValidationError("lookup_from must be an open Collection")
        if lookup_field is not None and (type(lookup_field) is not str or not lookup_field):
            raise ValidationError("lookup_field must be a nonempty field name")
        if timeout_ns is not None and (type(timeout_ns) is not int or timeout_ns <= 0):
            raise ValidationError("query timeout must be a positive integer")
        deadline = 0 if timeout_ns is None else monotonic_ns() + timeout_ns
        return self._call(
            "recommend_field_columns" if columns else "recommend_field", name,
            [_vector_value(item) for item in positive], [_vector_value(item) for item in negative], k,
            {"strategy": strategy, "mode": mode, "ef_search": -1 if ef_search is None else ef_search,
             "max_examples": self.limits.max_query_batch,
             "lookup_from": None if lookup_from is None else lookup_from._kernel,
             "lookup_field": lookup_field, "filter": None if filter is None else dict(filter),
             "cancelled": bool(cancellation and cancellation.cancelled),
             "deadline_ns": deadline, "max_candidates": self.limits.max_candidates},
        )

    def search_field_by_id(
        self, name: str, id: int, k: int, *,
        lookup_from: "Collection | None" = None, lookup_field: str | None = None,
        filter: Mapping[str, Any] | None = None, mode: str = "exact",
        ef_search: int | None = None, rerank_k: int = 0,
        ivf: IvfOptions | None = None, mmr: MmrOptions | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> list[SearchResult]:
        """Search with a stored vector; exclude its ID only for same-collection lookup."""
        raw = self._search_field_raw(
            name, id, k, _by_id=True, lookup_from=lookup_from, lookup_field=lookup_field,
            filter=filter, mode=mode, ef_search=ef_search, rerank_k=rerank_k,
            ivf=ivf, mmr=mmr, cancellation=cancellation, timeout_ns=timeout_ns,
        )
        return [SearchResult(**item) for item in raw]

    def _search_field_raw(
        self, name: str, vector: Any, k: int, *,
        filter: Mapping[str, Any] | None = None, mode: str = "exact",
        ef_search: int | None = None, rerank_k: int = 0, columns: bool = False,
        ivf: IvfOptions | None = None, mmr: MmrOptions | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
        _by_id: bool = False, lookup_from: "Collection | None" = None,
        lookup_field: str | None = None,
    ) -> Any:
        if _by_id:
            if type(vector) is not int:
                raise ValidationError("point ID must be an integer")
            if lookup_from is not None and not isinstance(lookup_from, Collection):
                raise ValidationError("lookup_from must be an open Collection")
            if lookup_field is not None and (type(lookup_field) is not str or not lookup_field):
                raise ValidationError("lookup_field must be a nonempty field name")
        if type(k) is not int or not 0 < k <= self.limits.max_k:
            raise ValidationError("named search k exceeds resource limit")
        if mode not in ("exact", "approx", "ivf"):
            raise ValidationError("named search mode must be exact, approx or ivf")
        if ef_search is not None and (type(ef_search) is not int or ef_search <= 0):
            raise ValidationError("ef_search must be a positive integer")
        if type(rerank_k) is not int or rerank_k < 0 or (rerank_k and rerank_k < k):
            raise ValidationError("rerank_k must be zero or at least k")
        if mode != "approx" and (ef_search is not None or rerank_k):
            raise ValidationError("ef_search and rerank_k require approximate field search")
        if ivf is not None and (mode != "ivf" or not isinstance(ivf, IvfOptions)):
            raise ValidationError("IvfOptions require ivf mode")
        if mmr is not None and not isinstance(mmr, MmrOptions):
            raise ValidationError("mmr must be MmrOptions")
        if mmr is not None and mmr.candidates_limit is not None and mmr.candidates_limit > self.limits.max_k:
            raise ValidationError("MMR candidates_limit exceeds query k resource limit")
        if timeout_ns is not None and (type(timeout_ns) is not int or timeout_ns <= 0):
            raise ValidationError("query timeout must be a positive integer")
        deadline = 0 if timeout_ns is None else monotonic_ns() + timeout_ns
        method = "search_field_by_id" if _by_id else "search_field"
        return self._call(
            method + "_columns" if columns else method, name,
            _vector_value(vector), k,
            {"filter": None if filter is None else dict(filter), "mode": mode,
             "ef_search": -1 if ef_search is None else ef_search, "rerank_k": rerank_k,
             "ivf": (ivf or IvfOptions()).to_kernel() if mode == "ivf" else None,
             "mmr": None if mmr is None else mmr.to_kernel(),
             "lookup_from": None if lookup_from is None else lookup_from._kernel,
             "lookup_field": lookup_field,
             "cancelled": bool(cancellation and cancellation.cancelled),
             "deadline_ns": deadline, "max_candidates": self.limits.max_candidates},
        )

    def search_fields(
        self, queries: list[FieldQuery], k: int, *, fetch_k: int = 100,
        rank_constant: int = 2, filter: Mapping[str, Any] | None = None,
        fusion: str = "rrf",
        weights: list[float] | None = None,
        rerank: FieldQuery | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> list[SearchResult]:
        raw = self._search_fields_raw(queries, k, fetch_k=fetch_k, rank_constant=rank_constant,
                                      filter=filter, fusion=fusion, weights=weights, rerank=rerank, cancellation=cancellation, timeout_ns=timeout_ns)
        return [SearchResult(**item) for item in raw]

    def _search_fields_raw(
        self, queries: list[FieldQuery], k: int, *, fetch_k: int = 100,
        rank_constant: int = 2, filter: Mapping[str, Any] | None = None,
        fusion: str = "rrf",
        weights: list[float] | None = None,
        rerank: FieldQuery | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
        columns: bool = False,
    ) -> Any:
        if type(fusion) is not str or fusion not in {"rrf", "dbsf"}:
            raise ValidationError("field fusion must be rrf or dbsf")
        if weights is not None:
            if fusion != "rrf":
                raise ValidationError("weights require RRF fusion")
            if not isinstance(weights, list) or len(weights) != len(queries):
                raise ValidationError("RRF weights must be a list matching the number of branches")
        if type(k) is not int or not 0 < k <= self.limits.max_k:
            raise ValidationError("named fusion k exceeds resource limit")
        if type(fetch_k) is not int or not k <= fetch_k <= self.limits.max_k:
            raise ValidationError("fetch_k must be at least k and fit the resource limit")
        if type(rank_constant) is not int or rank_constant <= 0:
            raise ValidationError("RRF rank constant must be a positive integer")
        if not 0 < len(queries) <= self.limits.max_query_batch:
            raise ValidationError("field fusion branch count exceeds resource limit")
        if any(not isinstance(query, FieldQuery) for query in queries):
            raise ValidationError("field fusion requires FieldQuery branches")
        if rerank is not None and (not isinstance(rerank, FieldQuery) or rerank.mode != "exact"):
            raise ValidationError("final field reranking requires an exact FieldQuery")
        if timeout_ns is not None and (type(timeout_ns) is not int or timeout_ns <= 0):
            raise ValidationError("query timeout must be a positive integer")
        deadline = 0 if timeout_ns is None else monotonic_ns() + timeout_ns
        return self._call(
            "search_fields_columns" if columns else "search_fields",
            [query.to_kernel() for query in queries],
            {"k": k, "fetch_k": fetch_k, "rank_constant": rank_constant,
             "fusion": fusion, "weights": weights,
             "rerank": None if rerank is None else rerank.to_kernel(),
             "filter": None if filter is None else dict(filter),
             "cancelled": bool(cancellation and cancellation.cancelled),
             "deadline_ns": deadline, "max_candidates": self.limits.max_candidates},
        )

    def upsert_sparse(self, id: int, elements: list[SparseElement]) -> None:
        self._call("upsert_sparse", id, [item.to_kernel() for item in elements])

    def apply_batch(self, mutations: list[BatchMutation]) -> BatchWriteResult:
        if len(mutations) > self.limits.max_batch_rows:
            raise ValidationError("mutation batch resource limit exceeded")
        raw = self._call(
            "apply_batch", [mutation.to_kernel() for mutation in mutations]
        )
        return BatchWriteResult(
            first_sequence=int(raw["first_sequence"]),
            last_sequence=int(raw["last_sequence"]),
            count=int(raw["count"]),
        )

    def delete(self, id: int) -> None:
        self._call("delete", id)

    def flush(self) -> None:
        self._call("flush")

    def backup(self, target: str | Path) -> dict[str, Any]:
        return dict(self._call("backup_to", str(target)))

    def _export_records(self) -> list[dict[str, Any]]:
        return list(self._call("export_records"))

    def _export_points(self) -> dict[str, Any] | None:
        value = self._call("export_points")
        return None if value is None else dict(value)

    def _is_point_collection(self) -> bool:
        return bool(self._call("is_point_collection"))

    def get(self, id: int, *, projection: Projection | None = None) -> Document | None:
        raw = (
            self._call("get", id)
            if projection is None
            else self._call("get_projected", id, projection.to_kernel())
        )
        if raw is None:
            return None
        return Document(
            id=int(raw["id"]),
            sequence=int(raw["sequence"]),
            vector=[float(value) for value in raw["vector"]],
            fields=[PayloadField(**item) for item in raw["fields"]],
        )

    def search(self, request: SearchRequest) -> list[SearchResult]:
        return [
            SearchResult(id=int(item["id"]), score=float(item["score"]))
            for item in self._search_raw(request)
        ]

    def _search_raw(self, request: SearchRequest, *, columns: bool = False) -> Any:
        suffix = "_columns" if columns else ""
        if request.k > self.limits.max_k:
            raise ValidationError("query k resource limit exceeded")
        vector = request.vector
        sparse = [item.to_kernel() for item in request.sparse]
        if request.filter is not None and request.mode == "sparse":
            raw = self._call(
                "search_sparse_where" + suffix,
                sparse,
                {"k": request.k, "filter": request.filter},
            )
        elif request.filter is not None and request.mode == "hybrid":
            if vector is None:
                raise ValidationError("hybrid search requires a dense vector")
            raw = self._call(
                "search_hybrid_where" + suffix,
                request.metric,
                vector,
                sparse,
                {
                    "k": request.k,
                    "fetch_k": request.fetch_k,
                    "rank_constant": request.rank_constant,
                    "filter": request.filter,
                },
            )
        elif request.filter is not None:
            if vector is None:
                raise ValidationError("dense search requires a vector")
            raw = self._call(
                "search_dense_where" + suffix,
                request.metric,
                vector,
                {
                    "k": request.k,
                    "approximate": request.mode == "approx",
                    "ef_search": request.ef_search,
                    "filter": request.filter,
                },
            )
        elif request.mode == "sparse":
            raw = self._call("search_sparse" + suffix, sparse, request.k)
        elif request.mode == "hybrid":
            if vector is None:
                raise ValidationError("hybrid search requires a dense vector")
            raw = self._call(
                "search_hybrid" + suffix,
                request.metric,
                vector,
                sparse,
                {
                    "k": request.k,
                    "fetch_k": request.fetch_k,
                    "rank_constant": request.rank_constant,
                },
            )
        elif request.mode == "approx":
            if vector is None:
                raise ValidationError("approximate search requires a dense vector")
            raw = self._call(
                "search_approx" + suffix,
                request.metric,
                vector,
                request.k,
                request.ef_search,
            )
        else:
            if vector is None:
                raise ValidationError("exact search requires a dense vector")
            method = {
                "dot": "search_dot",
                "l2": "search_l2",
                "cosine": "search_cosine",
            }[request.metric]
            raw = self._call(method + suffix, vector, request.k)
        return raw

    def search_batch(
        self,
        metric: str,
        vectors: list[list[float]],
        k: int,
        *,
        num_workers: int = 0,
        filters: list[dict[str, Any]] | None = None,
    ) -> list[list[SearchResult]]:
        if len(vectors) > self.limits.max_query_batch:
            raise ValidationError("query batch resource limit exceeded")
        if k > self.limits.max_k:
            raise ValidationError("query k resource limit exceeded")
        if filters is None:
            raw = self._call("search_batch", metric, vectors, k, num_workers)
        else:
            raw = self._call(
                "search_batch_where",
                metric,
                vectors,
                filters,
                k,
                num_workers,
            )
        return [
            [
                SearchResult(id=int(item["id"]), score=float(item["score"]))
                for item in query_results
            ]
            for query_results in raw
        ]

    def search_controlled(
        self,
        metric: str,
        vector: list[float],
        k: int,
        *,
        cancellation: "CancellationToken | None" = None,
        timeout_ns: int | None = None,
    ) -> list[SearchResult]:
        if k > self.limits.max_k:
            raise ValidationError("query k resource limit exceeded")
        if timeout_ns is not None and timeout_ns <= 0:
            raise ValidationError("query timeout must be positive")
        deadline = 0 if timeout_ns is None else monotonic_ns() + timeout_ns
        raw = self._call(
            "search_controlled",
            metric,
            vector,
            k,
            {
                "cancelled": cancellation.cancelled if cancellation else False,
                "deadline_ns": deadline,
                "max_candidates": self.limits.max_candidates,
            },
        )
        return [
            SearchResult(id=int(item["id"]), score=float(item["score"]))
            for item in raw
        ]


class CancellationToken:
    """Thread-safe Python cancellation source for controlled kernel calls."""

    def __init__(self) -> None:
        self._event = Event()

    def cancel(self) -> None:
        self._event.set()

    @property
    def cancelled(self) -> bool:
        return self._event.is_set()


def _json_query_options(timeout_ns, cancellation):
    if timeout_ns is not None and (type(timeout_ns) is not int or timeout_ns <= 0):
        raise ValidationError("timeout_ns must be a positive integer")
    return {"deadline_ns": 0 if timeout_ns is None else monotonic_ns() + timeout_ns,
            "cancelled": bool(cancellation and cancellation.cancelled)}


def _validate_json_arguments(expression, indexes):
    if not isinstance(expression, Mapping):
        raise ValidationError("expression must be a mapping")
    if indexes is not None and (not isinstance(indexes, list) or any(type(name) is not str for name in indexes)):
        raise ValidationError("indexes must be a list of index names")


class PreparedJsonQuery:
    """Owned native snapshot; close explicitly or use as a context manager.

    Cancellation is checked at call entry; timeout applies to each execution.
    """

    def __init__(self, kernel):
        self._kernel = kernel

    def execute(self, *, timeout_ns: int | None = None,
                cancellation: CancellationToken | None = None) -> list[int]:
        options = _json_query_options(timeout_ns, cancellation)
        try:
            return self._kernel.execute(options)
        except Exception as error:
            raise map_kernel_error(error) from error

    def close(self) -> None:
        self._kernel.close()

    def __enter__(self) -> "PreparedJsonQuery":
        return self

    def __exit__(self, *exc) -> None:
        self.close()


class LocalDatabase:
    """Named local collection registry for CLI and HTTP adapters."""

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._collections: dict[str, Collection] = {}

    def open(
        self,
        name: str,
        dimension: int,
        *,
        config: CollectionConfig | dict[str, Any] | None = None,
        vectors: dict[str, VectorField] | None = None,
    ) -> Collection:
        if not name or "/" in name or "\\" in name or name in {".", ".."}:
            raise ValidationError("collection name must be one safe path component")
        if name in self._collections:
            collection = self._collections[name]
            if collection.dimension != dimension:
                raise ValidationError("open collection dimension mismatch")
            try:
                requested = CollectionConfig.from_options(dimension, config)
            except (TypeError, ValueError) as error:
                raise ValidationError(str(error)) from error
            if collection.collection_config() != requested:
                raise ValidationError("open collection configuration mismatch")
            if vectors is not None and collection.vector_fields() != vectors:
                raise ValidationError("open collection vector schema mismatch")
            return collection
        collection = Collection(self.root / name, dimension, config=config, vectors=vectors)
        self._collections[name] = collection
        return collection

    def collection(self, name: str) -> Collection:
        try:
            return self._collections[name]
        except KeyError as error:
            raise CollectionNotFoundError(f"collection is not open: {name}") from error

    def close(self, name: str) -> None:
        collection = self.collection(name)
        collection.close()
        del self._collections[name]

    def close_all(self) -> None:
        for name in list(self._collections):
            self.close(name)

    def metrics(self) -> dict[str, object]:
        collections: dict[str, dict[str, int]] = {}
        for name, collection in self._collections.items():
            snapshot = collection.metrics()
            collections[name] = {
                "operations": snapshot.operations,
                "writes": snapshot.writes,
                "queries": snapshot.queries,
                "failures": snapshot.failures,
                "cancellations": snapshot.cancellations,
                "total_duration_ns": snapshot.total_duration_ns,
            }
        return {"open_collections": len(self._collections), "collections": collections}
