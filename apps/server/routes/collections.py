"""Collection lifecycle and checkpoint routes."""

from fastapi import APIRouter, Request

from apps.server.schemas import OpenCollectionRequest


router = APIRouter(prefix="/collections", tags=["collections"])


@router.post("/{name}")
def open_collection(
    name: str, body: OpenCollectionRequest, request: Request
) -> dict[str, object]:
    collection = request.app.state.database.open(name, body.dimension)
    return {
        "name": name,
        "dimension": collection.dimension,
        "last_sequence": collection.last_sequence,
    }


@router.delete("/{name}")
def close_collection(name: str, request: Request) -> dict[str, bool]:
    request.app.state.database.close(name)
    return {"closed": True}


@router.post("/{name}/flush")
def flush_collection(name: str, request: Request) -> dict[str, int]:
    collection = request.app.state.database.collection(name)
    collection.flush()
    return {"last_sequence": collection.last_sequence}
