"""In-process Python adapter over the compiled Mojo kernel extension."""

from pathlib import Path
from threading import Event
from time import monotonic_ns, perf_counter_ns
from typing import Any, Protocol

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
        kernel: KernelCollection | None = None,
        limits: ResourceLimits | None = None,
    ) -> None:
        try:
            requested = (
                None
                if config is None
                else CollectionConfig.from_options(dimension, config)
            )
        except (TypeError, ValueError) as error:
            raise ValidationError(str(error)) from error
        try:
            self._kernel: KernelCollection = (
                kernel
                if kernel is not None
                else (
                    _kernel_module().Collection(str(path), dimension)
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
        if request.k > self.limits.max_k:
            raise ValidationError("query k resource limit exceeded")
        vector = request.vector
        sparse = [item.to_kernel() for item in request.sparse]
        if request.filter is not None and request.mode == "sparse":
            raw = self._call(
                "search_sparse_where",
                sparse,
                {"k": request.k, "filter": request.filter},
            )
        elif request.filter is not None and request.mode == "hybrid":
            if vector is None:
                raise ValidationError("hybrid search requires a dense vector")
            raw = self._call(
                "search_hybrid_where",
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
                "search_dense_where",
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
            raw = self._call("search_sparse", sparse, request.k)
        elif request.mode == "hybrid":
            if vector is None:
                raise ValidationError("hybrid search requires a dense vector")
            raw = self._call(
                "search_hybrid",
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
                "search_approx", request.metric, vector, request.k, request.ef_search
            )
        else:
            if vector is None:
                raise ValidationError("exact search requires a dense vector")
            method = {
                "dot": "search_dot",
                "l2": "search_l2",
                "cosine": "search_cosine",
            }[request.metric]
            raw = self._call(method, vector, request.k)
        return [
            SearchResult(id=int(item["id"]), score=float(item["score"]))
            for item in raw
        ]

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
            return collection
        collection = Collection(self.root / name, dimension, config=config)
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
