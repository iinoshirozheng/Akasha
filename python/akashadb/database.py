"""In-process Python adapter over the compiled Mojo kernel extension."""

from pathlib import Path
from typing import Any, Protocol

from .exceptions import CollectionNotFoundError, ValidationError, map_kernel_error
from .models import (
    BatchMutation,
    BatchWriteResult,
    Document,
    PayloadField,
    Projection,
    SearchRequest,
    SearchResult,
    SparseElement,
)


class KernelCollection(Protocol):
    def close(self) -> None: ...
    def last_sequence(self) -> int: ...
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
        kernel: KernelCollection | None = None,
    ) -> None:
        try:
            self._kernel: KernelCollection = (
                kernel
                if kernel is not None
                else _kernel_module().Collection(str(path), dimension)
            )
        except Exception as error:
            raise map_kernel_error(error) from error
        self.path = Path(path)
        self.dimension = dimension

    def _call(self, method: str, *args: object) -> Any:
        try:
            return getattr(self._kernel, method)(*args)
        except Exception as error:
            raise map_kernel_error(error) from error

    def close(self) -> None:
        self._call("close")

    @property
    def last_sequence(self) -> int:
        return int(self._call("last_sequence"))

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


class LocalDatabase:
    """Named local collection registry for CLI and HTTP adapters."""

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._collections: dict[str, Collection] = {}

    def open(self, name: str, dimension: int) -> Collection:
        if not name or "/" in name or "\\" in name or name in {".", ".."}:
            raise ValidationError("collection name must be one safe path component")
        if name in self._collections:
            collection = self._collections[name]
            if collection.dimension != dimension:
                raise ValidationError("open collection dimension mismatch")
            return collection
        collection = Collection(self.root / name, dimension)
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
