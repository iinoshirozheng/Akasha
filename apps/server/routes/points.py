"""Point mutation, lookup, and search routes."""

from fastapi import APIRouter, HTTPException, Request
from dataclasses import asdict
from starlette.concurrency import run_in_threadpool

from akashadb import PayloadField, SearchRequest, SparseElement, ValidationError
from akashadb.payload import decode_payload
from apps.server.schemas import (SearchRequestBody, UpsertRequest, SetPayloadRequest,
                                OverwritePayloadRequest, DeletePayloadRequest, PayloadSelectorRequest)


router = APIRouter(prefix="/collections", tags=["points"])


def _payload(body: OverwritePayloadRequest) -> dict[str, object]:
    try:
        return decode_payload(body.payload) if body.encoding == "typed" else body.payload
    except (ValueError, TypeError) as error:
        raise ValidationError(str(error)) from error


def _field(item) -> PayloadField:
    value = item.model_dump()
    if value["encoding"] is None:
        del value["encoding"]
    try:
        return PayloadField.from_wire(value)
    except (ValueError, TypeError) as error:
        raise ValidationError(str(error)) from error


@router.post("/{name}/points/payload")
def set_payload(name: str, body: SetPayloadRequest, request: Request) -> dict[str, int]:
    collection = request.app.state.database.collection(name)
    return asdict(collection.set_payload(_payload(body), points=body.points, filter=body.filter, key=body.key))


@router.put("/{name}/points/payload")
def overwrite_payload(name: str, body: OverwritePayloadRequest, request: Request) -> dict[str, int]:
    collection = request.app.state.database.collection(name)
    return asdict(collection.overwrite_payload(_payload(body), points=body.points, filter=body.filter))


@router.post("/{name}/points/payload/delete")
def delete_payload(name: str, body: DeletePayloadRequest, request: Request) -> dict[str, int]:
    collection = request.app.state.database.collection(name)
    return asdict(collection.delete_payload(body.keys, points=body.points, filter=body.filter))


@router.post("/{name}/points/payload/clear")
def clear_payload(name: str, body: PayloadSelectorRequest, request: Request) -> dict[str, int]:
    collection = request.app.state.database.collection(name)
    return asdict(collection.clear_payload(points=body.points, filter=body.filter))


@router.post("/{name}/points")
def upsert_point(
    name: str, body: UpsertRequest, request: Request
) -> dict[str, int]:
    collection = request.app.state.database.collection(name)
    fields = None
    if body.fields is not None:
        fields = [_field(item) for item in body.fields]
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
        "fields": [item.to_wire() for item in document.fields],
    }


@router.post("/{name}/search")
async def search_points(
    name: str, body: SearchRequestBody, request: Request
) -> list[dict[str, object]]:
    collection = request.app.state.database.collection(name)
    results = await run_in_threadpool(
        collection.search,
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
