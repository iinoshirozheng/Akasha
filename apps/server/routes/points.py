"""Point mutation, lookup, and search routes."""

from fastapi import APIRouter, HTTPException, Request

from akashadb import PayloadField, SearchRequest, SparseElement
from apps.server.schemas import SearchRequestBody, UpsertRequest


router = APIRouter(prefix="/collections", tags=["points"])


@router.post("/{name}/points")
def upsert_point(
    name: str, body: UpsertRequest, request: Request
) -> dict[str, int]:
    collection = request.app.state.database.collection(name)
    fields = None
    if body.fields is not None:
        fields = [PayloadField(**item.model_dump()) for item in body.fields]
    collection.upsert(body.id, body.vector, fields)
    if body.sparse is not None:
        collection.upsert_sparse(
            body.id, [SparseElement(**item.model_dump()) for item in body.sparse]
        )
    return {"last_sequence": collection.last_sequence}


@router.delete("/{name}/points/{point_id}")
def delete_point(
    name: str, point_id: int, request: Request
) -> dict[str, int]:
    collection = request.app.state.database.collection(name)
    collection.delete(point_id)
    return {"last_sequence": collection.last_sequence}


@router.get("/{name}/points/{point_id}")
def get_point(name: str, point_id: int, request: Request) -> dict[str, object]:
    document = request.app.state.database.collection(name).get(point_id)
    if document is None:
        raise HTTPException(status_code=404, detail="point not found")
    return {
        "id": document.id,
        "sequence": document.sequence,
        "vector": document.vector,
        "fields": [
            {"name": item.name, "type": item.type, "value": item.value}
            for item in document.fields
        ],
    }


@router.post("/{name}/search")
def search_points(
    name: str, body: SearchRequestBody, request: Request
) -> list[dict[str, object]]:
    collection = request.app.state.database.collection(name)
    results = collection.search(
        SearchRequest(
            metric=body.metric,
            k=body.k,
            vector=body.vector,
            sparse=[SparseElement(**item.model_dump()) for item in body.sparse],
            mode=body.mode,
            ef_search=body.ef_search,
            fetch_k=body.fetch_k,
            rank_constant=body.rank_constant,
            filter=body.filter,
        )
    )
    return [{"id": item.id, "score": item.score} for item in results]
