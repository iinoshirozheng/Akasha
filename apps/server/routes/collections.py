"""Collection lifecycle and checkpoint routes."""

from dataclasses import asdict

from fastapi import APIRouter, Request

from apps.server.schemas import OpenCollectionRequest, JsonIndexRequest, JsonExpressionRequest


router = APIRouter(prefix="/collections", tags=["collections"])


@router.post("/{name}")
def open_collection(
    name: str, body: OpenCollectionRequest, request: Request
) -> dict[str, object]:
    collection = request.app.state.database.open(
        name, body.dimension, config=body.collection_config()
    )
    return {
        "name": name,
        "dimension": collection.dimension,
        "last_sequence": collection.last_sequence,
        "config": asdict(collection.collection_config()),
    }


@router.get("/{name}/stats")
def collection_stats(name: str, request: Request) -> dict[str, object]:
    collection = request.app.state.database.collection(name)
    return {
        "config": asdict(collection.collection_config()),
        "last_search": asdict(collection.last_search_stats()),
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


@router.put("/{name}/json-indexes/{index_name}")
def create_json_index(name: str, index_name: str, body: JsonIndexRequest, request: Request) -> dict[str, bool]:
    request.app.state.database.collection(name).create_json_index(index_name, body.column, body.path)
    return {"created": True}


@router.get("/{name}/json-indexes")
def json_indexes(name: str, request: Request) -> dict[str, object]:
    return {"indexes": request.app.state.database.collection(name).json_indexes()}


@router.delete("/{name}/json-indexes/{index_name}")
def drop_json_index(name: str, index_name: str, request: Request) -> dict[str, bool]:
    request.app.state.database.collection(name).drop_json_index(index_name)
    return {"dropped": True}


@router.post("/{name}/json-query")
def query_json(name: str, body: JsonExpressionRequest, request: Request) -> dict[str, object]:
    ids = request.app.state.database.collection(name).query_json(
        body.expression, indexes=body.indexes, timeout_ns=body.timeout_ns)
    return {"ids": ids}


@router.post("/{name}/json-indexes/{index_name}/rebuild")
def rebuild_json_index(name: str, index_name: str, request: Request) -> dict[str, bool]:
    request.app.state.database.collection(name).rebuild_json_index(index_name)
    return {"rebuilt": True}
