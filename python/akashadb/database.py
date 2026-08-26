"""In-process Python adapter over the compiled Mojo kernel extension."""

from pathlib import Path
from typing import Any, Protocol

from .exceptions import CollectionNotFoundError, map_kernel_error
from .models import (
    Document,
    PayloadField,
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
    def upsert_sparse(self, id: int, elements: list[dict[str, object]]) -> None: ...
    def delete(self, id: int) -> None: ...
    def flush(self) -> None: ...
    def get(self, id: int) -> dict[str, Any] | None: ...
    def search_dot(self, vector: list[float], k: int) -> list[dict[str, Any]]: ...
    def search_l2(self, vector: list[float], k: int) -> list[dict[str, Any]]: ...
    def search_cosine(self, vector: list[float], k: int) -> list[dict[str, Any]]: ...
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

    def delete(self, id: int) -> None:
        self._call("delete", id)

    def flush(self) -> None:
        self._call("flush")

    def get(self, id: int) -> Document | None:
        raw = self._call("get", id)
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
        if request.mode == "sparse":
            raw = self._call("search_sparse", sparse, request.k)
        elif request.mode == "hybrid":
            if vector is None:
                raise ValueError("hybrid search requires a dense vector")
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
                raise ValueError("approximate search requires a dense vector")
            raw = self._call(
                "search_approx", request.metric, vector, request.k, request.ef_search
            )
        else:
            if vector is None:
                raise ValueError("exact search requires a dense vector")
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


class LocalDatabase:
    """Named local collection registry for CLI and HTTP adapters."""

    def __init__(self, root: str | Path) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._collections: dict[str, Collection] = {}

    def open(self, name: str, dimension: int) -> Collection:
        if not name or "/" in name or "\\" in name or name in {".", ".."}:
            raise ValueError("collection name must be one safe path component")
        if name in self._collections:
            return self._collections[name]
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
