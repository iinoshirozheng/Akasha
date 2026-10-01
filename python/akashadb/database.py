"""In-process Python adapter over the compiled Mojo kernel extension."""

from pathlib import Path
from threading import Event
from time import monotonic_ns, perf_counter_ns
from typing import Any, Mapping, Protocol

from .vectors import FieldQuery, IvfOptions, Point, PointMutation, VectorField, _vector_value
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
    def close(self) -> None: ...
    def last_sequence(self) -> int: ...
    def collection_config(self) -> dict[str, Any]: ...
    def last_search_stats(self) -> dict[str, Any]: ...
    def vector_fields(self) -> list[dict[str, Any]]: ...
    def apply_point_batch(self, mutations: list[dict[str, Any]]) -> dict[str, int]: ...
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

    def _record_operation(
        self, method: str, duration_ns: int, status: str, error: str | None
    ) -> None:
        self._operations += 1
        self._total_duration_ns += duration_ns
        if method.startswith(("search", "get")):
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

    def get_point(self, id: int) -> Point | None:
        raw = self._call("get_point", id)
        return None if raw is None else Point.from_kernel(raw)

    def search_field(
        self, name: str, vector: Any, k: int, *,
        filter: Mapping[str, Any] | None = None, mode: str = "exact",
        ef_search: int | None = None, rerank_k: int = 0,
        ivf: IvfOptions | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> list[SearchResult]:
        raw = self._search_field_raw(name, vector, k, filter=filter, mode=mode,
                                     ef_search=ef_search, rerank_k=rerank_k, ivf=ivf,
                                     cancellation=cancellation, timeout_ns=timeout_ns)
        return [SearchResult(**item) for item in raw]

    def _search_field_raw(
        self, name: str, vector: Any, k: int, *,
        filter: Mapping[str, Any] | None = None, mode: str = "exact",
        ef_search: int | None = None, rerank_k: int = 0, columns: bool = False,
        ivf: IvfOptions | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> Any:
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
        if timeout_ns is not None and (type(timeout_ns) is not int or timeout_ns <= 0):
            raise ValidationError("query timeout must be a positive integer")
        deadline = 0 if timeout_ns is None else monotonic_ns() + timeout_ns
        return self._call(
            "search_field_columns" if columns else "search_field", name,
            _vector_value(vector), k,
            {"filter": None if filter is None else dict(filter), "mode": mode,
             "ef_search": -1 if ef_search is None else ef_search, "rerank_k": rerank_k,
             "ivf": (ivf or IvfOptions()).to_kernel() if mode == "ivf" else None,
             "cancelled": bool(cancellation and cancellation.cancelled),
             "deadline_ns": deadline, "max_candidates": self.limits.max_candidates},
        )

    def search_fields(
        self, queries: list[FieldQuery], k: int, *, fetch_k: int = 100,
        rank_constant: int = 60, filter: Mapping[str, Any] | None = None,
        rerank: FieldQuery | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
    ) -> list[SearchResult]:
        raw = self._search_fields_raw(queries, k, fetch_k=fetch_k, rank_constant=rank_constant,
                                      filter=filter, rerank=rerank, cancellation=cancellation, timeout_ns=timeout_ns)
        return [SearchResult(**item) for item in raw]

    def _search_fields_raw(
        self, queries: list[FieldQuery], k: int, *, fetch_k: int = 100,
        rank_constant: int = 60, filter: Mapping[str, Any] | None = None,
        rerank: FieldQuery | None = None,
        cancellation: "CancellationToken | None" = None, timeout_ns: int | None = None,
        columns: bool = False,
    ) -> Any:
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
